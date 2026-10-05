import Darwin
import Foundation
import SwiftGateDomain

/// A report's own folder: its page, the guarded run view the page embeds, and a copy under
/// `runs/` of each run file the page links, within a byte budget, so the page opens with working
/// links after the plan state and run stores are gone, or from anywhere it is moved to. It holds no event store, ledger or spec page: only what passed the
/// view's guard, and the files the view names.
public struct RunReportFolder: Sendable {
  public static let pageName = "index.html"
  public static let viewName = "view.json"
  /// Where the page finds the copies, relative to itself.
  public static let evidenceBase = "runs/"

  public let directory: URL

  public init(directory: URL) {
    self.directory = directory
  }

  /// Why a folder couldn't be written or read; the message names the file, never its bytes.
  public struct Failure: Error, Sendable, Equatable, CustomStringConvertible {
    public let description: String

    public init(_ description: String) { self.description = description }
  }

  /// The most bytes of run files 1 report copies; a file or folder past what is left of it stays
  /// behind and the page names it without a link.
  public static let evidenceBudget = 256 * 1024 * 1024

  /// Which linked files a report copies, in copy order, and why each other one stays behind.
  public struct Carriage: Sendable, Equatable {
    /// 1 linked path the report doesn't copy.
    public struct Left: Sendable, Equatable {
      public let relative: String
      /// Why, for a damage row; `nil` when a carried file stands in for it, as a result bundle's
      /// test summary does, or when its run recorded that it was never written.
      public let reason: String?

      public init(relative: String, reason: String?) {
        self.relative = relative
        self.reason = reason
      }
    }

    /// Each file or folder the report copies, `<run id>/<run-relative path>`.
    public let carried: [String]
    public let left: [Left]

    public init(carried: [String], left: [Left]) {
      self.carried = carried
      self.left = left
    }
  }

  /// What a report of `linked` carries: `first` (the flows' videos and sheets) before the rest,
  /// each in path order, while `budget` lasts. A path no run directory holds, a result bundle,
  /// and a file past the budget stay behind. A flow's step log whose `sim verify` report counted
  /// no step was never written, so it stays behind as no damage.
  public static func carriage(
    _ linked: Set<String>, first: Set<String>, under runs: [URL], budget: Int = evidenceBudget
  ) -> Carriage {
    var carried: [String] = []
    var left: [Carriage.Left] = []
    var spent = 0
    let ordered = first.intersection(linked).sorted() + linked.subtracting(first).sorted()
    for relative in ordered {
      guard let source = source(relative, in: runs) else {
        if neverWritten(relative, in: runs) {
          left.append(.init(relative: relative, reason: nil))
          continue
        }
        left.append(
          .init(relative: relative, reason: "linked but not in its run directory, so not copied"))
        continue
      }
      if let summary = QAReport.testSummary(ofBundle: relative) {
        let standIn = linked.contains(summary) && Self.source(summary, in: runs) != nil
        left.append(
          .init(
            relative: relative,
            reason: standIn
              ? nil : "a result bundle, which a report doesn't copy, with no test summary beside it"
          ))
        continue
      }
      let bytes = Self.bytes(source)
      guard spent + bytes <= budget else {
        left.append(
          .init(
            relative: relative,
            reason: "\(Self.megabytes(bytes)) past what is left of the report's "
              + "\(Self.megabytes(budget)) budget for run files, so not copied"))
        continue
      }
      spent += bytes
      carried.append(relative)
    }
    return Carriage(carried: carried, left: left)
  }

  /// Whether `relative` is a `sim/` step log beside a `sim verify` report that counted no step:
  /// the batch stopped before its first capture, so `sim snap` never wrote the log.
  static func neverWritten(_ relative: String, in runs: [URL]) -> Bool {
    let suffix = "/sim/" + SimStep.logFileName
    guard relative.hasSuffix(suffix) else { return false }
    let report = String(relative.dropLast(SimStep.logFileName.count)) + SimVerifyReport.fileName
    guard let url = source(report, in: runs), let data = try? Data(contentsOf: url),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return false }
    return (object["stepCount"] as? Int) == 0
  }

  /// A file's size, or the sum of a folder's files.
  static func bytes(_ url: URL) -> Int {
    let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey, .isDirectoryKey]
    guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return 0 }
    guard values.isDirectory == true else { return values.fileSize ?? 0 }
    var total = 0
    let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys)
    while let child = walk?.nextObject() as? URL {
      guard let child = try? child.resourceValues(forKeys: Set(keys)), child.isRegularFile == true
      else { continue }
      total += child.fileSize ?? 0
    }
    return total
  }

  private static func megabytes(_ bytes: Int) -> String {
    let tenths = (bytes * 10 + 512 * 1024) / (1024 * 1024)
    return "\(tenths / 10).\(tenths % 10) MB"
  }

  /// `relative` under the first of `runs` that holds it; `nil` when none does.
  public static func source(_ relative: String, in runs: [URL]) -> URL? {
    runs.lazy.map { $0.appending(path: relative) }
      .first { FileManager.default.fileExists(atPath: $0.path) }
  }

  /// Copies each file `carriage` carries from `runs`, then writes the view and the page. Every
  /// file goes to a temporary name beside it and is renamed into place, so a reader never sees
  /// half a file. A copy already there at the same size is kept.
  public func write(page: Data, view: Data, carrying carriage: Carriage, from runs: [URL])
    throws(Failure)
  {
    try makeDirectory(directory)
    for relative in carriage.carried {
      guard let source = Self.source(relative, in: runs) else { continue }
      let target = directory.appending(path: Self.evidenceBase + relative)
      let exists = FileManager.default.fileExists(atPath: target.path)
      let rewritten = Self.rewrittenEvidence(source, relative: relative)
      if exists {
        if let rewritten, (try? Data(contentsOf: target)) == rewritten { continue }
        if rewritten == nil, Self.bytes(target) == Self.bytes(source) { continue }
      }
      try makeDirectory(target.deletingLastPathComponent())
      let staging = staged(target)
      do {
        if let rewritten {
          try rewritten.write(to: staging)
        } else {
          try FileManager.default.copyItem(at: source, to: staging)
        }
      } catch {
        try? FileManager.default.removeItem(at: staging)
        throw Failure(
          "\(Self.evidenceBase)\(relative) can't be copied: \(error.localizedDescription)")
      }
      // A folder can't be renamed over a folder that holds files, so an older copy goes first.
      if exists, Self.isDirectory(target) { try? FileManager.default.removeItem(at: target) }
      try place(staging, at: target)
    }
    try publish(view, as: Self.viewName)
    try publish(page, as: Self.pageName)
  }

  /// A carried JSON file's bytes with its machine paths rewritten; `nil` for a folder, a file of
  /// another kind, or one that doesn't parse, which is copied as it is.
  static func rewrittenEvidence(_ source: URL, relative: String) -> Data? {
    guard RunEvidenceJSON.rewrites(source.lastPathComponent), !isDirectory(source),
      let runID = relative.split(separator: "/").first.map(String.init),
      let data = try? Data(contentsOf: source)
    else { return nil }
    return RunEvidenceJSON.relativized(data, runID: runID)
  }

  /// The view a folder's page was written from.
  public func storedView() throws(Failure) -> Data {
    do {
      return try Data(contentsOf: directory.appending(path: Self.viewName))
    } catch {
      throw Failure("\(Self.viewName) doesn't read: \(error.localizedDescription)")
    }
  }

  /// Whether the folder holds a final report: its page is written and the view it embeds is of
  /// a done run, not a snapshot of one still going.
  public var isFinal: Bool {
    guard FileManager.default.fileExists(atPath: directory.appending(path: Self.pageName).path),
      let data = try? Data(contentsOf: directory.appending(path: Self.viewName)),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let run = object["run"] as? [String: Any]
    else { return false }
    return run["state"] as? String == RunView.RunState.done.rawValue
      && (run["snapshotAt"] == nil || run["snapshotAt"] is NSNull)
  }

  /// Rewrites the page alone, from a view the folder already holds.
  public func writePage(_ page: Data) throws(Failure) {
    try publish(page, as: Self.pageName)
  }

  private func publish(_ data: Data, as name: String) throws(Failure) {
    let target = directory.appending(path: name)
    let staging = staged(target)
    do {
      try data.write(to: staging)
    } catch {
      try? FileManager.default.removeItem(at: staging)
      throw Failure("\(name) can't be written: \(error.localizedDescription)")
    }
    try place(staging, at: target)
  }

  private func staged(_ target: URL) -> URL {
    target.deletingLastPathComponent().appending(
      path: ".\(target.lastPathComponent).\(UUID().uuidString).tmp")
  }

  private func place(_ staging: URL, at target: URL) throws(Failure) {
    guard rename(staging.path, target.path) == 0 else {
      let reason = String(cString: strerror(errno))
      try? FileManager.default.removeItem(at: staging)
      throw Failure("\(target.lastPathComponent) can't be moved into place: \(reason)")
    }
  }

  private func makeDirectory(_ url: URL) throws(Failure) {
    do {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    } catch {
      throw Failure("\(url.lastPathComponent) can't be made: \(error.localizedDescription)")
    }
  }

  private static func isDirectory(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
  }
}

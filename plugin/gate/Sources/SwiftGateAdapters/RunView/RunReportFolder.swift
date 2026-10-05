import Darwin
import Foundation
import SwiftGateDomain

/// A report's own folder: its page, the guarded run view the page embeds, and a copy of each run
/// file its flows link under `runs/`, so the page opens with working links after the plan state
/// and run stores are gone. It holds no event store, ledger or spec page: only what passed the
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

  /// Each linked file, `<run id>/<run-relative path>`, that `runs` doesn't hold: the report can't
  /// copy it, so its link would break.
  public static func missing(_ linked: Set<String>, under runs: [URL]) -> [String] {
    linked.filter { source($0, in: runs) == nil }.sorted()
  }

  /// `relative` under the first of `runs` that holds it; `nil` when none does.
  public static func source(_ relative: String, in runs: [URL]) -> URL? {
    runs.lazy.map { $0.appending(path: relative) }
      .first { FileManager.default.fileExists(atPath: $0.path) }
  }

  /// Copies each linked file that `runs` holds, then writes the view and the page. Every file
  /// goes to a temporary name beside it and is renamed into place, so a reader never sees half a
  /// file. A copy already there at the same size is kept.
  public func write(page: Data, view: Data, linked: Set<String>, from runs: [URL]) throws(Failure) {
    try makeDirectory(directory)
    for relative in linked.sorted() {
      guard let source = Self.source(relative, in: runs) else { continue }
      let target = directory.appending(path: Self.evidenceBase + relative)
      if let have = size(target), have == size(source) { continue }
      try makeDirectory(target.deletingLastPathComponent())
      let staging = staged(target)
      do {
        try FileManager.default.copyItem(at: source, to: staging)
      } catch {
        try? FileManager.default.removeItem(at: staging)
        throw Failure(
          "\(Self.evidenceBase)\(relative) can't be copied: \(error.localizedDescription)")
      }
      try place(staging, at: target)
    }
    try publish(view, as: Self.viewName)
    try publish(page, as: Self.pageName)
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

  private func size(_ url: URL) -> Int? {
    (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
  }
}

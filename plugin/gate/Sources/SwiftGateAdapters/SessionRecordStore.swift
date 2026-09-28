import Foundation
import SwiftGateDomain

/// Session records under `.harness/hook-state/sessions/`, one `<session id>.json` each, inside
/// the hook state's own `.gitignore`, so a record never dirties `git status`.
public struct SessionRecordStore: Sendable {
  public static let directory = ".harness/hook-state/sessions"
  /// Records kept after a write; older ones are pruned.
  public static let retained = 20

  /// Every record that decoded, and every file that didn't with why.
  public struct Scan: Sendable, Equatable {
    public struct Unreadable: Sendable, Equatable {
      public let path: String
      public let reason: String

      public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
      }
    }

    public let records: [SessionRecord]
    public let unreadable: [Unreadable]

    public init(records: [SessionRecord], unreadable: [Unreadable]) {
      self.records = records
      self.unreadable = unreadable
    }

    /// The latest `recordedAt`, ties broken by session id.
    public var newest: SessionRecord? {
      records.max { ($0.recordedAt, $0.sessionId) < ($1.recordedAt, $1.sessionId) }
    }
  }

  public let worktreeRoot: URL

  public init(worktreeRoot: URL) {
    self.worktreeRoot = worktreeRoot
  }

  public var directoryURL: URL {
    worktreeRoot.appending(path: Self.directory, directoryHint: .isDirectory)
  }

  private var hookStateURL: URL { directoryURL.deletingLastPathComponent() }

  public func file(sessionID: String) throws(SessionRecordStoreError) -> URL {
    guard SessionRecord.isSafeSessionID(sessionID) else { throw .unsafeSessionID(sessionID) }
    return directoryURL.appending(path: sessionID + ".json")
  }

  /// Replaces the session's record atomically (a temp file renamed over it, so a reader sees
  /// the old record or the new one), then prunes to the newest ``retained`` by write time.
  /// Each session writes only its own file, so sessions starting at once never overwrite each
  /// other, and a fresh record is never among the oldest another session prunes.
  /// - Returns: a line per record that couldn't be pruned.
  @discardableResult
  public func write(_ record: SessionRecord) throws(SessionRecordStoreError) -> [String] {
    let url = try file(sessionID: record.sessionId)
    do {
      let data = try record.encoded()
      try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
      let ignore = hookStateURL.appending(path: ".gitignore")
      if !FileManager.default.fileExists(atPath: ignore.path) {
        try Data("*\n".utf8).write(to: ignore, options: .atomic)
      }
      try data.write(to: url, options: .atomic)
    } catch {
      throw .unwritable(path: url.path, reason: "\(error)")
    }
    return prune(keeping: url)
  }

  /// `nil` when the session has no record.
  public func record(sessionID: String) throws(SessionRecordStoreError) -> SessionRecord? {
    let url = try file(sessionID: sessionID)
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return nil
    } catch {
      throw .unreadable(path: url.path, reason: error.localizedDescription)
    }
    do {
      return try SessionRecord.decode(data)
    } catch {
      throw .unreadable(path: url.path, reason: error.description)
    }
  }

  public func scan() -> Scan {
    var records: [SessionRecord] = []
    var unreadable: [Scan.Unreadable] = []
    for url in recordFiles() {
      do {
        records.append(try SessionRecord.decode(Data(contentsOf: url)))
      } catch let error as SessionRecordError {
        unreadable.append(Scan.Unreadable(path: url.path, reason: error.description))
      } catch {
        unreadable.append(Scan.Unreadable(path: url.path, reason: error.localizedDescription))
      }
    }
    return Scan(records: records, unreadable: unreadable)
  }

  /// `<id>.json` files for safe ids; an atomic write's temp file and anything else is skipped.
  private func recordFiles() -> [URL] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path)) ?? []
    return names.filter {
      $0.hasSuffix(".json") && SessionRecord.isSafeSessionID(String($0.dropLast(5)))
    }.sorted().map { directoryURL.appending(path: $0) }
  }

  private func prune(keeping written: URL) -> [String] {
    let dated = recordFiles().compactMap { url in modified(url).map { (url: url, date: $0) } }
    guard dated.count > Self.retained else { return [] }
    let oldest = dated.sorted { ($0.date, $0.url.path) < ($1.date, $1.url.path) }
      .prefix(dated.count - Self.retained)
    var failures: [String] = []
    for entry in oldest where entry.url != written {
      // A session re-recording since the listing has a newer file there now; keep it.
      guard modified(entry.url) == entry.date else { continue }
      do {
        try FileManager.default.removeItem(at: entry.url)
      } catch let error as CocoaError where error.code == .fileNoSuchFile {
        continue
      } catch {
        failures.append(
          "Couldn't prune old session record \(entry.url.path): \(error.localizedDescription)")
      }
    }
    return failures
  }

  private func modified(_ url: URL) -> Date? {
    try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
  }
}

public enum SessionRecordStoreError: Error, Sendable, Equatable, CustomStringConvertible {
  case unsafeSessionID(String)
  case unwritable(path: String, reason: String)
  case unreadable(path: String, reason: String)

  public var description: String {
    switch self {
    case .unsafeSessionID(let id): SessionRecordError.unsafeSessionID(id).description
    case .unwritable(let path, let reason): "can't write \(path): \(reason)"
    case .unreadable(let path, let reason): "can't read \(path): \(reason)"
    }
  }
}

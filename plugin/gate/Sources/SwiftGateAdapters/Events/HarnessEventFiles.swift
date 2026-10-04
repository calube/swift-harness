import Darwin
import Foundation
import SwiftGateDomain

/// Why an event wasn't written, naming the file.
public struct HarnessEventWriteError: Error, Sendable, Equatable, CustomStringConvertible {
  public let path: String
  public let reason: String

  public init(path: String, reason: String) {
    self.path = path
    self.reason = reason
  }

  public var description: String { "\(path): \(reason)" }
}

/// Appends events to their streams. Any kind of event goes through 1 writer.
public protocol HarnessEventWriting: Sendable {
  func append(_ event: HarnessEvent) throws(HarnessEventWriteError)
  /// Appends `events` as 1 batch: a file writer makes 1 write per stream, so a batch never spans
  /// 2 segments.
  func append(contentsOf events: [HarnessEvent]) throws(HarnessEventWriteError)
}

extension HarnessEventWriting {
  public func append(contentsOf events: [HarnessEvent]) throws(HarnessEventWriteError) {
    for event in events { try append(event) }
  }
}

public struct HarnessEventReadError: Error, Sendable, Equatable, CustomStringConvertible {
  public let path: String
  public let reason: String

  public init(path: String, reason: String) {
    self.path = path
    self.reason = reason
  }

  public var description: String { "\(path): \(reason)" }
}

public protocol HarnessEventReading: Sendable {
  /// Where `stream` lives: the shared log, or 1 run's copy.
  func path(_ stream: HarnessEventStream, runID: String?) -> String
  /// The stream's bytes; `nil` when the file doesn't exist.
  func read(_ stream: HarnessEventStream, runID: String?) throws(HarnessEventReadError) -> Data?
}

/// `events/<stream>.jsonl` under a worktree's state root, plus a copy of each run's events in its run
/// directory. Each event is 1 `O_APPEND` write under an exclusive `flock`, so concurrent writers
/// never tear or interleave a line.
public struct HarnessEventFiles: HarnessEventWriting, HarnessEventReading {
  public let root: URL
  public let rotationBytes: @Sendable (HarnessEventStream) -> Int
  public let guardPolicy: @Sendable (HarnessEventStream) -> EventPayloadGuard.Policy

  public init(
    root: URL,
    rotationBytes: @escaping @Sendable (HarnessEventStream) -> Int = { $0.rotationBytes },
    guardPolicy: @escaping @Sendable (HarnessEventStream) -> EventPayloadGuard.Policy = {
      EventPayloadGuard.policy(for: $0)
    }
  ) {
    self.root = root
    self.rotationBytes = rotationBytes
    self.guardPolicy = guardPolicy
  }

  private var store: EventSegmentStore {
    EventSegmentStore(root: root, rotationBytes: rotationBytes)
  }

  /// A run's copy stays with its run directory in the worktree; the shared log is wherever
  /// ``StateRootResolver/eventStore(worktree:)`` puts it.
  public func path(_ stream: HarnessEventStream, runID: String?) -> String {
    if let runID {
      return StateRootResolver.resolve(worktree: root)
        .url(RunLayout.runEventsFile(stream, runID: runID)).path
    }
    return StateRootResolver.eventStore(worktree: root).url(RunLayout.eventsFile(stream)).path
  }

  public func append(_ event: HarnessEvent) throws(HarnessEventWriteError) {
    try append(contentsOf: [event])
  }

  /// Guards each event, then makes 1 write per stream to the shared log and 1 per run copy. An
  /// event the guard rejects is counted in `dropped.json` and left out; the others are written,
  /// then the call throws naming each dropped kind and reason.
  public func append(contentsOf events: [HarnessEvent]) throws(HarnessEventWriteError) {
    guard !events.isEmpty else { return }
    var accepted: [HarnessEvent] = []
    var dropped: [String] = []
    for event in events {
      if guardPolicy(event.kind.stream) == .enforced {
        let reason: EventPayloadGuard.Reason?
        do {
          reason = try EventPayloadGuard.rejection(of: event)
        } catch {
          throw HarnessEventWriteError(
            path: path(event.kind.stream, runID: nil), reason: "encode: \(error)")
        }
        if let reason {
          try store.countDropped(event.kind, reason)
          dropped.append("\(event.kind.rawValue) \(reason.rawValue)")
          continue
        }
      }
      accepted.append(event)
    }
    var shared: [(HarnessEventStream, Data)] = []
    var copies: [(String, Data)] = []
    for event in accepted {
      let stream = event.kind.stream
      let line: Data
      do {
        line = try HarnessEventJSON.encodeLine(event)
      } catch {
        throw HarnessEventWriteError(path: path(stream, runID: nil), reason: "encode: \(error)")
      }
      Self.add(line, under: stream, to: &shared)
      if let runID = event.runID, RunID.isValid(runID) {
        Self.add(line, under: path(stream, runID: runID), to: &copies)
      }
    }
    // Every write is tried, so a log that fails, or a segment that won't seal, costs no run its
    // copy; the first failure is thrown after.
    var failure: HarnessEventWriteError?
    for (stream, lines) in shared {
      do throws(HarnessEventWriteError) {
        try store.append(lines, to: stream)
      } catch {
        failure = failure ?? error
      }
    }
    for (path, lines) in copies {
      do throws(AppendOnlyFile.Failure) {
        try AppendOnlyFile.append(lines, to: path, creatingDirectory: true)
      } catch {
        failure = failure ?? HarnessEventWriteError(path: path, reason: error.reason)
      }
    }
    if let failure { throw failure }
    if !shared.isEmpty,
      !FileManager.default.fileExists(
        atPath: root.appending(path: EventSegmentLayout.storeFile).path)
    {
      _ = try store.identity()
    }
    if !dropped.isEmpty {
      throw HarnessEventWriteError(
        path: root.appending(path: EventSegmentLayout.droppedFile).path,
        reason: "the payload guard dropped \(dropped.count) of \(events.count) events: "
          + dropped.joined(separator: ", "))
    }
  }

  /// Appends `line` to `key`'s bytes, keeping keys in first-seen order.
  private static func add<Key: Equatable>(
    _ line: Data, under key: Key, to groups: inout [(Key, Data)]
  ) {
    if let at = groups.firstIndex(where: { $0.0 == key }) {
      groups[at].1.append(line)
    } else {
      groups.append((key, line))
    }
  }

  public func read(_ stream: HarnessEventStream, runID: String?) throws(HarnessEventReadError)
    -> Data?
  {
    if let runID, !RunID.isValid(runID) {
      throw HarnessEventReadError(path: runID, reason: "not a run id")
    }
    guard let runID else { return try store.read(stream) }
    let path = path(stream, runID: runID)
    do {
      return try Data(contentsOf: URL(filePath: path))
    } catch CocoaError.fileReadNoSuchFile {
      return nil
    } catch {
      throw HarnessEventReadError(path: path, reason: error.localizedDescription)
    }
  }
}

/// Appends whole lines to a file several processes share: 1 `O_APPEND` write under an exclusive
/// `flock`, so lines never interleave.
enum AppendOnlyFile {
  struct Failure: Error {
    let operation: String
    let detail: String

    var reason: String { "\(operation): \(detail)" }
  }

  static func append(_ line: Data, to path: String, creatingDirectory: Bool = false)
    throws(Failure)
  {
    if creatingDirectory {
      do {
        try FileManager.default.createDirectory(
          at: URL(filePath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
      } catch {
        throw Failure(operation: "mkdir", detail: error.localizedDescription)
      }
    }
    let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
    guard fd >= 0 else { throw posixFailure("open") }
    defer { close(fd) }
    guard flock(fd, LOCK_EX) == 0 else { throw posixFailure("flock") }
    defer { flock(fd, LOCK_UN) }
    try writeAll(line, to: fd)
  }

  /// Writes all of `data` to `fd`, resuming after a partial write or an interrupt.
  static func writeAll(_ data: Data, to fd: Int32) throws(Failure) {
    var offset = 0
    while offset < data.count {
      let written = data.withUnsafeBytes { buffer -> Int in
        guard let base = buffer.baseAddress else { return 0 }
        return write(fd, base + offset, buffer.count - offset)
      }
      if written < 0 {
        if errno == EINTR { continue }
        throw posixFailure("write")
      }
      offset += written
    }
  }

  static func posixFailure(_ operation: String) -> Failure {
    Failure(operation: operation, detail: String(cString: strerror(errno)))
  }
}

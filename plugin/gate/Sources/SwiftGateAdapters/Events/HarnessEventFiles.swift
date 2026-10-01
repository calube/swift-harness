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

/// `.harness/events/<stream>.jsonl` under a worktree, plus a copy of each run's events in its run
/// directory. Each event is 1 `O_APPEND` write under an exclusive `flock`, so concurrent writers
/// never tear or interleave a line.
public struct HarnessEventFiles: HarnessEventWriting, HarnessEventReading {
  public let root: URL

  public init(root: URL) {
    self.root = root
  }

  public func path(_ stream: HarnessEventStream, runID: String?) -> String {
    root.appending(
      path: runID.map { RunLayout.runEventsFile(stream, runID: $0) } ?? RunLayout.eventsFile(stream)
    ).path
  }

  /// To the shared log, then to the run's copy when the event names a valid run.
  public func append(_ event: HarnessEvent) throws(HarnessEventWriteError) {
    let shared = path(event.kind.stream, runID: nil)
    let line: Data
    do {
      line = try HarnessEventJSON.encodeLine(event)
    } catch {
      throw HarnessEventWriteError(path: shared, reason: "encode: \(error)")
    }
    var paths = [shared]
    if let runID = event.runID, RunID.isValid(runID) {
      paths.append(path(event.kind.stream, runID: runID))
    }
    for path in paths {
      do throws(AppendOnlyFile.Failure) {
        try AppendOnlyFile.append(line, to: path, creatingDirectory: true)
      } catch {
        throw HarnessEventWriteError(path: path, reason: error.reason)
      }
    }
  }

  public func read(_ stream: HarnessEventStream, runID: String?) throws(HarnessEventReadError)
    -> Data?
  {
    if let runID, !RunID.isValid(runID) {
      throw HarnessEventReadError(path: runID, reason: "not a run id")
    }
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
    var offset = 0
    while offset < line.count {
      let written = line.withUnsafeBytes { buffer -> Int in
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

  private static func posixFailure(_ operation: String) -> Failure {
    Failure(operation: operation, detail: String(cString: strerror(errno)))
  }
}

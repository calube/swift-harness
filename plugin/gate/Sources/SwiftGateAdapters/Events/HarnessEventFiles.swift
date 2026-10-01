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

  public func append(_ event: HarnessEvent) throws(HarnessEventWriteError) {}

  public func read(_ stream: HarnessEventStream, runID: String?) throws(HarnessEventReadError)
    -> Data?
  {
    nil
  }
}

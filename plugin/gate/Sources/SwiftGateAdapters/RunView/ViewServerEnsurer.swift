import Darwin
import Foundation
import SwiftGateDomain

/// The saved ``ViewServerRecord`` of 1 repository, in its git common dir.
public struct ViewServerRegistry: Sendable {
  public let file: URL

  /// Where the detached server's output goes.
  public let log: URL

  public init(commonDirectory: URL) {
    let directory = commonDirectory.appending(
      path: RunLayout.gitDirDirectory, directoryHint: .isDirectory)
    file = directory.appending(path: ViewServerRecord.fileName)
    log = directory.appending(path: ViewServerRecord.logName)
  }

  /// `nil` when there is none or it doesn't decode.
  public func read() -> ViewServerRecord? {
    nil
  }

  /// Replaces the record through a temporary file, so a reader never sees half of it.
  public func write(_ record: ViewServerRecord) throws {}
}

/// Whether a saved server still answers as itself.
public protocol ViewServerProbing: Sendable {
  func answers(_ record: ViewServerRecord) async -> Bool
}

/// `view --ensure`: reuses the repository's viewer server when it still answers, or starts a
/// detached one and waits until it saves its record.
public struct ViewServerEnsurer: Sendable {
  public enum Outcome: Sendable, Equatable {
    case off
    case reused(ViewServerRecord)
    case started(ViewServerRecord)
  }

  public struct Failure: Error, Sendable, Equatable, CustomStringConvertible {
    public let description: String

    public init(_ description: String) { self.description = description }
  }

  public let registry: ViewServerRegistry
  public let probe: any ViewServerProbing
  public let launcher: any DetachedLaunching
  /// How long a started server has to save its record.
  public let startDeadline: Duration
  public let wait: @Sendable (Duration) async throws -> Void

  public init(
    registry: ViewServerRegistry, probe: any ViewServerProbing, launcher: any DetachedLaunching,
    startDeadline: Duration = .seconds(20),
    wait: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.registry = registry
    self.probe = probe
    self.launcher = launcher
    self.startDeadline = startDeadline
    self.wait = wait
  }

  /// - Parameters:
  ///   - switchValue: `SWIFTGATE_VIEW`'s value.
  ///   - serve: the arguments that run a detached server, before its `--port`.
  public func ensure(
    switchValue: String?, executable: String, serve: [String], directory: String
  ) async throws(Failure) -> Outcome {
    .off
  }
}

/// ``ViewServerProbing`` over a live pid and the server's `/server` answer.
public struct LiveViewServerProbe: ViewServerProbing {
  public init() {}

  public func answers(_ record: ViewServerRecord) async -> Bool {
    false
  }
}


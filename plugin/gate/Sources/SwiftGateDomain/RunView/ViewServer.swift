import Foundation

/// Where a repository's detached viewer server listens, saved so the next `view --ensure` hands
/// out the same URL instead of starting a second server.
public struct ViewServerRecord: Sendable, Equatable, Codable {
  /// Under the git common dir's harness directory, so every worktree of the repository finds it.
  public static let fileName = "view-server.json"
  /// The detached server's output, beside the record.
  public static let logName = "view-server.log"

  public var pid: Int32
  public var port: Int
  public var startedAt: Date

  public init(pid: Int32, port: Int, startedAt: Date) {
    self.pid = pid
    self.port = port
    self.startedAt = startedAt
  }

  /// The page's address.
  public var url: String { "http://127.0.0.1:\(port)/" }

  public static func decode(_ data: Data) throws -> ViewServerRecord {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(ViewServerRecord.self, from: data)
  }

  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(self)
  }
}

/// The `SWIFTGATE_VIEW` switch: `off` starts no server and prints no URL.
public enum ViewServerSwitch {
  public static let environmentKey = "SWIFTGATE_VIEW"

  /// Whether `value`, the variable's value, turns the live viewer off.
  public static func isOff(_ value: String?) -> Bool {
    false
  }
}

/// What `view --ensure` does, from the switch and the saved record.
public enum ViewEnsureDecision: Sendable, Equatable {
  /// `SWIFTGATE_VIEW=off`.
  case off
  /// The saved server still answers as itself.
  case reuse(ViewServerRecord)
  /// No server answers: start 1, asking first for the port the last one had.
  case start(preferredPort: Int?)

  /// - Parameter answering: whether the server `record` names still answers with its own pid.
  public static func decide(
    switchValue: String?, record: ViewServerRecord?, answering: Bool
  ) -> ViewEnsureDecision {
    .start(preferredPort: nil)
  }
}

/// When a detached viewer server exits: a set time after its run's final report exists, or
/// after a long stretch with no request and no change to the run.
public struct ViewServerLifetime: Sendable, Equatable {
  public static let idleLimit: TimeInterval = 2 * 60 * 60
  public static let afterFinal: TimeInterval = 10 * 60

  public enum ExitReason: String, Sendable, Equatable {
    case idle
    case finished
  }

  /// The last request or run change.
  public private(set) var lastActivity: Date
  /// When the final report was first seen; `nil` while there is none.
  public private(set) var finalSince: Date?

  public init(startedAt: Date) {
    lastActivity = startedAt
  }

  public mutating func noteActivity(at time: Date) {}

  /// Records whether the final report exists at `time`; a report that went away, as when a
  /// resumed build makes the run running again, clears it.
  public mutating func noteFinal(_ exists: Bool, at time: Date) {}

  /// Why the server should exit at `now`; `nil` while it should keep serving.
  public func exitReason(at now: Date) -> ExitReason? {
    nil
  }
}

/// Drives a ``ViewServerLifetime`` on a clock: each tick asks `observe` what happened, and the
/// watch returns once the lifetime says to exit. The clock and the wait are injected, so a test
/// runs 2 hours of ticks without sleeping.
public struct ViewServerWatch: Sendable {
  /// What 1 tick found.
  public struct Observation: Sendable, Equatable {
    /// Whether a request came or the run's files moved since the last tick.
    public var active: Bool
    /// Whether the run's final report exists.
    public var finalExists: Bool

    public init(active: Bool, finalExists: Bool) {
      self.active = active
      self.finalExists = finalExists
    }
  }

  public static let tick: Duration = .seconds(15)

  public init() {}

  public func run(
    now: @Sendable () -> Date,
    wait: @Sendable (Duration) async throws -> Void,
    observe: @Sendable () -> Observation
  ) async throws -> ViewServerLifetime.ExitReason {
    .idle
  }
}

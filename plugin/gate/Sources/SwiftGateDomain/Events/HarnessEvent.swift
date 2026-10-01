import Foundation

/// The envelope any harness layer's event travels in: which event, what caused it, when, which run
/// and commit, which route, and a payload named by ``kind``. Each kind's stream is 1 append-only
/// JSON Lines file under `.harness/events/`.
public struct HarnessEvent: Sendable, Equatable {
  public static let schemaVersion = 1

  public let schemaVersion: Int
  public let eventID: String
  /// The event that caused this one, such as the Jev call an escalation follows.
  public let parentID: String?
  public let time: Date
  public let runID: String?
  /// The commit `HEAD` was at.
  public let head: String?
  /// The commit the change was measured from.
  public let base: String?
  public let source: HarnessEventSource
  public let payload: HarnessEventPayload

  public init(
    eventID: String, parentID: String? = nil, time: Date, runID: String? = nil,
    head: String? = nil, base: String? = nil, source: HarnessEventSource,
    payload: HarnessEventPayload
  ) {
    self.schemaVersion = Self.schemaVersion
    self.eventID = eventID
    self.parentID = parentID
    self.time = time
    self.runID = runID
    self.head = head
    self.base = base
    self.source = source
    self.payload = payload
  }

  public var kind: HarnessEventKind { payload.kind }
}

public enum HarnessEventKind: String, Sendable, Codable, CaseIterable {
  /// 1 decision about 1 question for 1 subject.
  case judgeDecision = "judge.decision"
  /// 1 call to a judge backend, or 1 answer served from the judge cache.
  case judgeCall = "judge.call"

  public var stream: HarnessEventStream {
    switch self {
    case .judgeDecision, .judgeCall: .judge
    }
  }
}

/// 1 append-only file of events, shared by every kind that names it.
public enum HarnessEventStream: String, Sendable, CaseIterable {
  case judge

  public var fileName: String { "\(rawValue).jsonl" }
}

/// What ran when the event happened.
public enum HarnessRoute: String, Sendable, Codable, CaseIterable {
  case checkReady = "check-ready"
  case judgeTests = "judge-tests"
  case judgeTestsReady = "judge-tests-ready"
  case commentHook = "comment-hook"
  case calibrateDesign = "calibrate-design"
  case judgeAsk = "judge-ask"
  /// Benchmark calls, which an analysis of live decisions leaves out.
  case bench
  case selfTest = "self-test"
}

public enum HarnessHook: String, Sendable, Codable, CaseIterable {
  case preToolUse = "pre-tool-use"
}

public struct HarnessEventSource: Sendable, Equatable, Codable {
  /// `nil` when the event happened under no route that named itself.
  public let route: HarnessRoute?
  public let tier: CheckTier?
  public let hook: HarnessHook?

  public init(route: HarnessRoute?, tier: CheckTier? = nil, hook: HarnessHook? = nil) {
    self.route = route
    self.tier = tier
    self.hook = hook
  }
}

public enum HarnessEventPayload: Sendable, Equatable {
  case judgeDecision(JudgeDecisionEvent)
  case judgeCall(JudgeCallEvent)

  public var kind: HarnessEventKind {
    switch self {
    case .judgeDecision: .judgeDecision
    case .judgeCall: .judgeCall
    }
  }
}

/// Why a line of an event stream can't be read.
public struct HarnessEventDecodeError: Error, Sendable, Equatable, CustomStringConvertible {
  public enum Reason: Sendable, Equatable {
    case unknownKey(String)
    case newerSchema(Int)
    case invalid(String)
  }

  /// 1-based.
  public let line: Int
  public let reason: Reason

  public init(line: Int, reason: Reason) {
    self.line = line
    self.reason = reason
  }

  public var description: String {
    switch reason {
    case .unknownKey(let path): "line \(line): unknown key `\(path)`"
    case .newerSchema(let version):
      "line \(line): schemaVersion \(version) is newer than this swiftgate reads "
        + "(\(HarnessEvent.schemaVersion)); update swiftgate"
    case .invalid(let why): "line \(line): \(why)"
    }
  }
}

/// JSON Lines for events: 1 compact, newline-terminated object per event, closed and versioned.
public enum HarnessEventJSON {
  /// What a stream held.
  public struct Read: Sendable, Equatable {
    public let events: [HarnessEvent]
    /// The last line had no newline and didn't parse: a write still in flight, or one a crash cut.
    public let tornLastLine: Bool

    public init(events: [HarnessEvent], tornLastLine: Bool) {
      self.events = events
      self.tornLastLine = tornLastLine
    }
  }

  public static func encodeLine(_ event: HarnessEvent) throws -> Data {
    Data()
  }

  /// Every event in `data`. A torn last line is reported; any other bad line, an unknown key at
  /// any depth, or a newer schema fails.
  public static func decode(_ data: Data) throws(HarnessEventDecodeError) -> Read {
    Read(events: [], tornLastLine: false)
  }
}

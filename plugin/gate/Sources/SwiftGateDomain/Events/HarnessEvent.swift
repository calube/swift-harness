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

  /// This event with `binary` in its source, unless its source already names one.
  public func stamped(_ binary: GateBinary?) -> HarnessEvent {
    guard let binary, source.binary == nil else { return self }
    return HarnessEvent(
      eventID: eventID, parentID: parentID, time: time, runID: runID, head: head, base: base,
      source: HarnessEventSource(
        route: source.route, tier: source.tier, hook: source.hook, binary: binary),
      payload: payload)
  }
}

public enum HarnessEventKind: String, Sendable, Codable, CaseIterable {
  /// 1 decision about 1 question for 1 subject.
  case judgeDecision = "judge.decision"
  /// 1 call to a judge backend, or 1 answer served from the judge cache.
  case judgeCall = "judge.call"
  /// 1 recorded gate run.
  case gateRun = "gate.run"
  /// 1 timed step of a recorded gate run.
  case gateStep = "gate.step"
  /// 1 call of a Claude Code hook.
  case hookDecision = "hook.decision"
  /// 1 test case of a recorded gate run.
  case testResult = "test.result"
  /// 1 read or write of an on-disk answer cache.
  case cacheLookup = "cache.lookup"
  /// 1 API message's token counts, read from a Claude Code transcript.
  case agentUsage = "agent.usage"
  /// A build stopped to wait on a person.
  case buildHalt = "build.halt"
  /// A person answered a build's halt.
  case buildResume = "build.resume"
  /// `build check-return` judged 1 task's return.
  case buildReturnChecked = "build.return-checked"
  /// 1 `swiftgate discover` in a brownfield clone.
  case discoverRun = "discover.run"
  /// 1 area's 1 step of a brownfield warm-up.
  case warmupRun = "warmup.run"
  /// A run phase began.
  case spanStart = "span.start"
  /// A run phase ended.
  case spanEnd = "span.end"
  /// 1 changed test `prove` ran.
  case proveResult = "prove.result"
  /// 1 agent's tool calls in 1 window, read from a Claude Code transcript.
  case agentTools = "agent.tools"
  /// 1 validation row in 1 `qa run`.
  case qaCheck = "qa.check"
  /// 1 flow's steps, from a batch `qa run` drove or a kept XCUITest.
  case qaFlow = "qa.flow"
  /// A requirement's rewritten flow taken into plan state.
  case qaRepair = "qa.repair"
  /// 1 setup step of 1 `qa run`: its tree, or a row's device, build or install.
  case qaSetup = "qa.setup"

  public var stream: HarnessEventStream {
    switch self {
    case .judgeDecision, .judgeCall: .judge
    case .gateRun, .gateStep: .gate
    case .hookDecision: .hook
    case .testResult, .proveResult: .test
    case .cacheLookup: .cache
    case .agentUsage, .agentTools: .usage
    case .buildHalt, .buildResume, .buildReturnChecked: .build
    case .discoverRun, .warmupRun: .brownfield
    case .spanStart, .spanEnd: .span
    case .qaCheck, .qaFlow, .qaRepair, .qaSetup: .qa
    }
  }
}

/// 1 append-only file of events, shared by every kind that names it.
public enum HarnessEventStream: String, Sendable, CaseIterable {
  case judge
  case gate
  case hook
  case test
  case cache
  case usage
  case build
  case brownfield
  case span
  case qa

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
  /// A gate run's record.
  case check
  /// A Claude Code hook call.
  case hook
  /// `swiftgate events ingest` reading transcripts.
  case ingest
}

public enum HarnessHook: String, Sendable, Codable, CaseIterable {
  case preToolUse = "pre-tool-use"
  case sessionStart = "session-start"
  case postToolUse = "post-tool-use"
  case stop
}

public struct HarnessEventSource: Sendable, Equatable, Codable {
  /// `nil` when the event happened under no route that named itself.
  public let route: HarnessRoute?
  public let tier: CheckTier?
  public let hook: HarnessHook?
  /// The binary that wrote the event; `nil` when it ran without `bin/swiftgate`.
  public let binary: GateBinary?

  public init(
    route: HarnessRoute?, tier: CheckTier? = nil, hook: HarnessHook? = nil,
    binary: GateBinary? = nil
  ) {
    self.route = route
    self.tier = tier
    self.hook = hook
    self.binary = binary
  }
}

public enum HarnessEventPayload: Sendable, Equatable {
  case judgeDecision(JudgeDecisionEvent)
  case judgeCall(JudgeCallEvent)
  case gateRun(GateRunEvent)
  case gateStep(GateStepEvent)
  case hookDecision(HookDecisionEvent)
  case testResult(TestResultEvent)
  case cacheLookup(CacheLookupEvent)
  case agentUsage(AgentUsageEvent)
  case buildHalt(BuildHaltEvent)
  case buildResume(BuildResumeEvent)
  case buildReturnChecked(BuildReturnCheckedEvent)
  case discoverRun(DiscoverRunEvent)
  case warmupRun(WarmupRunEvent)
  case spanStart(SpanStartEvent)
  case spanEnd(SpanEndEvent)
  case proveResult(ProveResultEvent)
  case agentTools(AgentToolsEvent)
  case qaCheck(QACheckEvent)
  case qaFlow(QAFlowEvent)
  case qaRepair(QARepairEvent)
  case qaSetup(QASetupEvent)

  public var kind: HarnessEventKind {
    switch self {
    case .judgeDecision: .judgeDecision
    case .judgeCall: .judgeCall
    case .gateRun: .gateRun
    case .gateStep: .gateStep
    case .hookDecision: .hookDecision
    case .testResult: .testResult
    case .cacheLookup: .cacheLookup
    case .agentUsage: .agentUsage
    case .buildHalt: .buildHalt
    case .buildResume: .buildResume
    case .buildReturnChecked: .buildReturnChecked
    case .discoverRun: .discoverRun
    case .warmupRun: .warmupRun
    case .spanStart: .spanStart
    case .spanEnd: .spanEnd
    case .proveResult: .proveResult
    case .agentTools: .agentTools
    case .qaCheck: .qaCheck
    case .qaFlow: .qaFlow
    case .qaRepair: .qaRepair
    case .qaSetup: .qaSetup
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
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(date.formatted(Self.timeFormat))
    }
    var data = try encoder.encode(event)
    data.append(UInt8(ascii: "\n"))
    return data
  }

  /// Every event in `data`. A torn last line is reported; any other bad line, an unknown key at
  /// any depth, or a newer schema fails.
  public static func decode(_ data: Data) throws(HarnessEventDecodeError) -> Read {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let text = try container.decode(String.self)
      guard let date = try? Date(text, strategy: Self.timeFormat) else {
        throw DecodingError.dataCorruptedError(
          in: container, debugDescription: "`\(text)` isn't an ISO 8601 time")
      }
      return date
    }
    let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
    let endsWithNewline = data.last == UInt8(ascii: "\n")
    var events: [HarnessEvent] = []
    for (index, line) in lines.enumerated() where !line.isEmpty {
      let number = index + 1
      let isLast = index == lines.count - 1
      do throws(HarnessEventDecodeError) {
        events.append(try decodeLine(Data(line), number: number, decoder: decoder))
      } catch {
        // Only an unfinished final write is a tear; a whole line that fails is corruption.
        if isLast, !endsWithNewline, case .invalid = error.reason {
          return Read(events: events, tornLastLine: true)
        }
        throw error
      }
    }
    return Read(events: events, tornLastLine: false)
  }

  /// Seconds to the millisecond, so events within 1 second still sort.
  static let timeFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

  private static func decodeLine(_ line: Data, number: Int, decoder: JSONDecoder)
    throws(HarnessEventDecodeError) -> HarnessEvent
  {
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: line)
    } catch {
      throw HarnessEventDecodeError(line: number, reason: .invalid("not JSON"))
    }
    if let version = (object as? [String: Any])?["schemaVersion"] as? Int,
      version > HarnessEvent.schemaVersion
    {
      throw HarnessEventDecodeError(line: number, reason: .newerSchema(version))
    }
    let event: HarnessEvent
    do {
      event = try decoder.decode(HarnessEvent.self, from: line)
    } catch {
      throw HarnessEventDecodeError(line: number, reason: .invalid(describe(error)))
    }
    // A key this version doesn't know would be dropped by decoding, so it fails instead: whatever
    // decoding kept, encoding writes back, and anything else in the line is unknown.
    let known: Any
    do {
      known = try JSONSerialization.jsonObject(with: try encodeLine(event))
    } catch {
      throw HarnessEventDecodeError(line: number, reason: .invalid("\(error)"))
    }
    if let unknown = unknownKey(in: object, known: known, path: []) {
      throw HarnessEventDecodeError(line: number, reason: .unknownKey(unknown))
    }
    return event
  }

  private static func unknownKey(in value: Any, known: Any, path: [String]) -> String? {
    if let object = value as? [String: Any] {
      let knownObject = known as? [String: Any] ?? [:]
      for key in object.keys.sorted() where !(object[key] is NSNull) {
        guard let knownValue = knownObject[key] else {
          return (path + [key]).joined(separator: ".")
        }
        if let found = unknownKey(in: object[key] as Any, known: knownValue, path: path + [key]) {
          return found
        }
      }
    } else if let array = value as? [Any], let knownArray = known as? [Any] {
      for (index, element) in array.enumerated() where index < knownArray.count {
        if let found = unknownKey(
          in: element, known: knownArray[index], path: path + ["\(index)"])
        {
          return found
        }
      }
    }
    return nil
  }

  private static func describe(_ error: any Error) -> String {
    guard let error = error as? DecodingError else { return "\(error)" }
    func at(_ context: DecodingError.Context) -> String {
      let path = context.codingPath.map(\.stringValue).joined(separator: ".")
      return (path.isEmpty ? "" : "`\(path)`: ") + context.debugDescription
    }
    switch error {
    case .keyNotFound(let key, let context):
      return
        "missing key `\((context.codingPath + [key]).map(\.stringValue).joined(separator: "."))`"
    case .typeMismatch(_, let context), .valueNotFound(_, let context),
      .dataCorrupted(let context):
      return at(context)
    @unknown default:
      return "\(error)"
    }
  }
}

extension HarnessEvent: Codable {
  private enum CodingKeys: String, CodingKey {
    case schemaVersion, eventID, parentID, kind, time, runID, head, base, source, payload
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
    guard schemaVersion == Self.schemaVersion else {
      throw DecodingError.dataCorruptedError(
        forKey: .schemaVersion, in: c,
        debugDescription: "unsupported schemaVersion \(schemaVersion)")
    }
    eventID = try c.decode(String.self, forKey: .eventID)
    parentID = try c.decodeIfPresent(String.self, forKey: .parentID)
    time = try c.decode(Date.self, forKey: .time)
    runID = try c.decodeIfPresent(String.self, forKey: .runID)
    head = try c.decodeIfPresent(String.self, forKey: .head)
    base = try c.decodeIfPresent(String.self, forKey: .base)
    source = try c.decode(HarnessEventSource.self, forKey: .source)
    switch try c.decode(HarnessEventKind.self, forKey: .kind) {
    case .judgeDecision:
      payload = .judgeDecision(try c.decode(JudgeDecisionEvent.self, forKey: .payload))
    case .judgeCall:
      payload = .judgeCall(try c.decode(JudgeCallEvent.self, forKey: .payload))
    case .gateRun:
      payload = .gateRun(try c.decode(GateRunEvent.self, forKey: .payload))
    case .gateStep:
      payload = .gateStep(try c.decode(GateStepEvent.self, forKey: .payload))
    case .hookDecision:
      payload = .hookDecision(try c.decode(HookDecisionEvent.self, forKey: .payload))
    case .testResult:
      payload = .testResult(try c.decode(TestResultEvent.self, forKey: .payload))
    case .cacheLookup:
      payload = .cacheLookup(try c.decode(CacheLookupEvent.self, forKey: .payload))
    case .agentUsage:
      payload = .agentUsage(try c.decode(AgentUsageEvent.self, forKey: .payload))
    case .buildHalt:
      payload = .buildHalt(try c.decode(BuildHaltEvent.self, forKey: .payload))
    case .buildResume:
      payload = .buildResume(try c.decode(BuildResumeEvent.self, forKey: .payload))
    case .buildReturnChecked:
      payload = .buildReturnChecked(
        try c.decode(BuildReturnCheckedEvent.self, forKey: .payload))
    case .discoverRun:
      payload = .discoverRun(try c.decode(DiscoverRunEvent.self, forKey: .payload))
    case .warmupRun:
      payload = .warmupRun(try c.decode(WarmupRunEvent.self, forKey: .payload))
    case .spanStart:
      payload = .spanStart(try c.decode(SpanStartEvent.self, forKey: .payload))
    case .spanEnd:
      payload = .spanEnd(try c.decode(SpanEndEvent.self, forKey: .payload))
    case .proveResult:
      payload = .proveResult(try c.decode(ProveResultEvent.self, forKey: .payload))
    case .agentTools:
      payload = .agentTools(try c.decode(AgentToolsEvent.self, forKey: .payload))
    case .qaCheck:
      payload = .qaCheck(try c.decode(QACheckEvent.self, forKey: .payload))
    case .qaFlow:
      payload = .qaFlow(try c.decode(QAFlowEvent.self, forKey: .payload))
    case .qaRepair:
      payload = .qaRepair(try c.decode(QARepairEvent.self, forKey: .payload))
    case .qaSetup:
      payload = .qaSetup(try c.decode(QASetupEvent.self, forKey: .payload))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(schemaVersion, forKey: .schemaVersion)
    try c.encode(eventID, forKey: .eventID)
    try c.encodeIfPresent(parentID, forKey: .parentID)
    try c.encode(kind, forKey: .kind)
    try c.encode(time, forKey: .time)
    try c.encodeIfPresent(runID, forKey: .runID)
    try c.encodeIfPresent(head, forKey: .head)
    try c.encodeIfPresent(base, forKey: .base)
    try c.encode(source, forKey: .source)
    switch payload {
    case .judgeDecision(let decision): try c.encode(decision, forKey: .payload)
    case .judgeCall(let call): try c.encode(call, forKey: .payload)
    case .gateRun(let run): try c.encode(run, forKey: .payload)
    case .gateStep(let step): try c.encode(step, forKey: .payload)
    case .hookDecision(let hook): try c.encode(hook, forKey: .payload)
    case .testResult(let result): try c.encode(result, forKey: .payload)
    case .cacheLookup(let lookup): try c.encode(lookup, forKey: .payload)
    case .agentUsage(let usage): try c.encode(usage, forKey: .payload)
    case .buildHalt(let halt): try c.encode(halt, forKey: .payload)
    case .buildResume(let resume): try c.encode(resume, forKey: .payload)
    case .buildReturnChecked(let checked): try c.encode(checked, forKey: .payload)
    case .discoverRun(let run): try c.encode(run, forKey: .payload)
    case .warmupRun(let run): try c.encode(run, forKey: .payload)
    case .spanStart(let start): try c.encode(start, forKey: .payload)
    case .spanEnd(let end): try c.encode(end, forKey: .payload)
    case .proveResult(let result): try c.encode(result, forKey: .payload)
    case .agentTools(let tools): try c.encode(tools, forKey: .payload)
    case .qaCheck(let check): try c.encode(check, forKey: .payload)
    case .qaFlow(let flow): try c.encode(flow, forKey: .payload)
    case .qaRepair(let repair): try c.encode(repair, forKey: .payload)
    case .qaSetup(let setup): try c.encode(setup, forKey: .payload)
    }
  }
}

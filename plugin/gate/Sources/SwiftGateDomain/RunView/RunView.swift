import Foundation

/// What a run viewer page draws: 1 build run's spans, gates, proofs, tokens and halts. The same
/// shape is embedded in a report and streamed to a live page, which merges each array by id.
/// Every string comes from a guarded event, a ledger id or write set, a commit sha or a
/// requirement title.
public struct RunView: Sendable, Equatable, Encodable {
  public static let schemaVersion = 1

  /// Token counts summed over API messages.
  public struct Tokens: Sendable, Equatable, Encodable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
      self.input = input
      self.output = output
      self.cacheRead = cacheRead
      self.cacheWrite = cacheWrite
    }
  }

  public enum RunState: String, Sendable, Equatable, Encodable, CaseIterable {
    case running
    case done
    case halted
  }

  public struct Run: Sendable, Equatable, Encodable {
    public var id: String
    public var plan: String?
    /// The preset's name; `nil` when `run.json` didn't read.
    public var preset: String?
    public var startedAt: Date?
    public var endedAt: Date?
    public var state: RunState
    /// Minutes a worker may go quiet before the page flags it; `nil` when the preset doesn't say.
    public var stallMin: Int?

    public init(
      id: String, plan: String? = nil, preset: String? = nil, startedAt: Date? = nil,
      endedAt: Date? = nil, state: RunState = .running, stallMin: Int? = nil
    ) {
      self.id = id
      self.plan = plan
      self.preset = preset
      self.startedAt = startedAt
      self.endedAt = endedAt
      self.state = state
      self.stallMin = stallMin
    }
  }

  /// 1 requirement and the tasks that cover it; an uncovered one has no tasks.
  public struct SpecRow: Sendable, Equatable, Encodable {
    public var id: String
    /// At most ``RunView/maxTitleBytes`` UTF-8 bytes.
    public var title: String
    public var tasks: [String]

    public init(id: String, title: String, tasks: [String] = []) {
      self.id = id
      self.title = title
      self.tasks = tasks
    }
  }

  /// A task's ticket text, as `plan import` wrote it into the plan state.
  public struct Brief: Sendable, Equatable, Encodable {
    public var title: String
    public var why: String
    /// The design section the task implements, such as `§4.2`.
    public var designRef: String?
    public var scope: [String]
    public var acceptance: [String]
    public var outOfScope: [String]

    public init(
      title: String, why: String, designRef: String? = nil, scope: [String] = [],
      acceptance: [String] = [], outOfScope: [String] = []
    ) {
      self.title = title
      self.why = why
      self.designRef = designRef
      self.scope = scope
      self.acceptance = acceptance
      self.outOfScope = outOfScope
    }
  }

  public struct Task: Sendable, Equatable, Encodable {
    public var id: String
    public var status: TaskStatus
    public var model: TaskModel?
    public var deps: [String]
    /// The ledger's write set, repo-relative.
    public var writes: [String]
    public var gate: CheckTier
    public var covers: [String]
    public var commits: [String]
    public var gateRun: String?
    public var mergeGateRun: String?
    /// The task's first ledger event.
    public var createdAt: Date?
    public var mergedAt: Date?
    public var brief: Brief?
    /// `nil` while the task's worker runs: its usage is ingested when it finishes.
    public var tokens: Tokens?

    public init(
      id: String, status: TaskStatus, model: TaskModel? = nil, deps: [String] = [],
      writes: [String] = [], gate: CheckTier, covers: [String] = [], commits: [String] = [],
      gateRun: String? = nil, mergeGateRun: String? = nil, createdAt: Date? = nil,
      mergedAt: Date? = nil, brief: Brief? = nil, tokens: Tokens? = nil
    ) {
      self.id = id
      self.status = status
      self.model = model
      self.deps = deps
      self.writes = writes
      self.gate = gate
      self.covers = covers
      self.commits = commits
      self.gateRun = gateRun
      self.mergeGateRun = mergeGateRun
      self.createdAt = createdAt
      self.mergedAt = mergedAt
      self.brief = brief
      self.tokens = tokens
    }
  }

  public struct Role: Sendable, Equatable, Encodable {
    public var role: AgentRole
    public var tokens: Tokens

    public init(role: AgentRole, tokens: Tokens) {
      self.role = role
      self.tokens = tokens
    }
  }

  /// What a span stands for: a phase an event times, or 1 the builder derives.
  public enum Phase: String, Sendable, Equatable, Encodable, CaseIterable {
    case run
    case task
    case merge
    case gate
    case tier
    case step
    case specRead = "spec-read"
    case discover
    /// 1 area's warm-up step, derived from `warmup.run`.
    case warmup
    case explore
    case plan
    case contract
    case worker
    case review
    case verify
    case fix
    case final
    case ship
  }

  /// The tool calls attributed to 1 span.
  public struct ToolSummary: Sendable, Equatable, Encodable {
    public var calls: [ToolCallCount]
    public var otherCount: Int
    public var milliseconds: Int
    /// At most ``AgentToolsEvent/maxFiles``.
    public var files: [String]
    public var droppedPaths: Int

    public init(
      calls: [ToolCallCount] = [], otherCount: Int = 0, milliseconds: Int = 0,
      files: [String] = [], droppedPaths: Int = 0
    ) {
      self.calls = calls
      self.otherCount = otherCount
      self.milliseconds = milliseconds
      self.files = files
      self.droppedPaths = droppedPaths
    }

    private enum CodingKeys: String, CodingKey {
      case calls, otherCount, files, droppedPaths
      case milliseconds = "ms"
    }
  }

  public struct Span: Sendable, Equatable, Encodable {
    public var id: String
    public var parent: String?
    public var phase: Phase
    public var task: String?
    public var gateRun: String?
    public var start: Date
    /// `nil` for a span still open, or 1 that never ended.
    public var end: Date?
    public var outcome: SpanOutcome?
    /// Laid end to end because its gate step carried no start offset.
    public var approximate: Bool
    public var tools: ToolSummary?
    /// The RED gate run that turned this stage red; `nil` for a span whose own `gateRun` says,
    /// or one no gate run explains.
    public var causeGateRun: String?

    public init(
      id: String, parent: String? = nil, phase: Phase, task: String? = nil,
      gateRun: String? = nil, start: Date, end: Date? = nil, outcome: SpanOutcome? = nil,
      approximate: Bool = false, tools: ToolSummary? = nil, causeGateRun: String? = nil
    ) {
      self.id = id
      self.parent = parent
      self.phase = phase
      self.task = task
      self.gateRun = gateRun
      self.start = start
      self.end = end
      self.outcome = outcome
      self.approximate = approximate
      self.tools = tools
      self.causeGateRun = causeGateRun
    }
  }

  public struct GateStepRow: Sendable, Equatable, Encodable {
    public var tier: Tier?
    public var step: GateStep
    public var startMs: Int?
    public var milliseconds: Int
    public var verdict: Verdict

    public init(tier: Tier?, step: GateStep, startMs: Int?, milliseconds: Int, verdict: Verdict) {
      self.tier = tier
      self.step = step
      self.startMs = startMs
      self.milliseconds = milliseconds
      self.verdict = verdict
    }

    private enum CodingKeys: String, CodingKey {
      case tier, step, startMs, verdict
      case milliseconds = "ms"
    }
  }

  public struct Gate: Sendable, Equatable, Encodable {
    public var runID: String
    public var task: String?
    public var command: String?
    public var verdict: Verdict
    public var milliseconds: Int
    public var tests: TestCounts?
    public var ruleCounts: [String: Int]
    public var steps: [GateStepRow]
    /// Why the run wasn't GREEN; `nil` for a GREEN run.
    public var failure: GateFailure?

    public init(
      runID: String, task: String? = nil, command: String? = nil, verdict: Verdict,
      milliseconds: Int, tests: TestCounts? = nil, ruleCounts: [String: Int] = [:],
      steps: [GateStepRow] = [], failure: GateFailure? = nil
    ) {
      self.runID = runID
      self.task = task
      self.command = command
      self.verdict = verdict
      self.milliseconds = milliseconds
      self.tests = tests
      self.ruleCounts = ruleCounts
      self.steps = steps
      self.failure = failure
    }

    private enum CodingKeys: String, CodingKey {
      case task, command, verdict, tests, ruleCounts, steps
      case runID = "runId"
      case milliseconds = "ms"
    }
  }

  public struct Proof: Sendable, Equatable, Encodable {
    public var gateRun: String
    public var task: String?
    public var test: String
    public var outcome: ProveResultOutcome
    public var proofBase: String?
    public var assertion: ProveAssertion?

    public init(
      gateRun: String, task: String? = nil, test: String, outcome: ProveResultOutcome,
      proofBase: String? = nil, assertion: ProveAssertion? = nil
    ) {
      self.gateRun = gateRun
      self.task = task
      self.test = test
      self.outcome = outcome
      self.proofBase = proofBase
      self.assertion = assertion
    }
  }

  public struct Halt: Sendable, Equatable, Encodable {
    public var task: String?
    public var reason: BuildHaltReason
    public var at: Date
    public var answer: BuildResumeAnswer?
    public var waitMs: Int?
    /// The RED gate run a `gate-red` halt stopped on; `nil` for another reason, or when no
    /// RED gate run of the halt's task came before it.
    public var gateRun: String?

    public init(
      task: String? = nil, reason: BuildHaltReason, at: Date, answer: BuildResumeAnswer? = nil,
      waitMs: Int? = nil, gateRun: String? = nil
    ) {
      self.task = task
      self.reason = reason
      self.at = at
      self.answer = answer
      self.waitMs = waitMs
      self.gateRun = gateRun
    }
  }

  /// A file or value the view couldn't use, shown in the page footer, never a silent gap.
  public struct Damage: Sendable, Equatable, Encodable {
    public var source: String
    public var reason: String

    public init(source: String, reason: String) {
      self.source = source
      self.reason = reason
    }
  }

  /// A requirement title's cap.
  public static let maxTitleBytes = 120
  /// A brief string's cap.
  public static let maxBriefBytes = 480

  public var schemaVersion: Int { Self.schemaVersion }
  /// Where a live page's next poll starts; `nil` in a report.
  public var cursor: String?
  public var run: Run
  public var spec: [SpecRow]
  public var tasks: [Task]
  public var roles: [Role]
  public var spans: [Span]
  public var gates: [Gate]
  public var proofs: [Proof]
  public var halts: [Halt]
  public var damage: [Damage]

  public init(
    cursor: String? = nil, run: Run, spec: [SpecRow] = [], tasks: [Task] = [], roles: [Role] = [],
    spans: [Span] = [], gates: [Gate] = [], proofs: [Proof] = [], halts: [Halt] = [],
    damage: [Damage] = []
  ) {
    self.cursor = cursor
    self.run = run
    self.spec = spec
    self.tasks = tasks
    self.roles = roles
    self.spans = spans
    self.gates = gates
    self.proofs = proofs
    self.halts = halts
    self.damage = damage
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, cursor, run, spec, tasks, roles, spans, gates, proofs, halts, damage
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(schemaVersion, forKey: .schemaVersion)
    try c.encode(cursor, forKey: .cursor)
    try c.encode(run, forKey: .run)
    try c.encode(spec, forKey: .spec)
    try c.encode(tasks, forKey: .tasks)
    try c.encode(roles, forKey: .roles)
    try c.encode(spans, forKey: .spans)
    try c.encode(gates, forKey: .gates)
    try c.encode(proofs, forKey: .proofs)
    try c.encode(halts, forKey: .halts)
    try c.encode(damage, forKey: .damage)
  }
}

// Each type with an optional field spells its encoding out: the synthesized one leaves an absent
// value's key out, and the page reads `null` as the 1 spelling of "not known".

extension RunView.Run {
  private enum CodingKeys: String, CodingKey {
    case id, plan, preset, startedAt, endedAt, state, stallMin
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(plan, forKey: .plan)
    try c.encode(preset, forKey: .preset)
    try c.encode(startedAt, forKey: .startedAt)
    try c.encode(endedAt, forKey: .endedAt)
    try c.encode(state, forKey: .state)
    try c.encode(stallMin, forKey: .stallMin)
  }
}

extension RunView.Brief {
  private enum CodingKeys: String, CodingKey {
    case title, why, designRef, scope, acceptance, outOfScope
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(title, forKey: .title)
    try c.encode(why, forKey: .why)
    try c.encode(designRef, forKey: .designRef)
    try c.encode(scope, forKey: .scope)
    try c.encode(acceptance, forKey: .acceptance)
    try c.encode(outOfScope, forKey: .outOfScope)
  }
}

extension RunView.Task {
  private enum CodingKeys: String, CodingKey {
    case id, status, model, deps, writes, gate, covers, commits, gateRun, mergeGateRun
    case createdAt, mergedAt, brief, tokens
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(status, forKey: .status)
    try c.encode(model, forKey: .model)
    try c.encode(deps, forKey: .deps)
    try c.encode(writes, forKey: .writes)
    try c.encode(gate, forKey: .gate)
    try c.encode(covers, forKey: .covers)
    try c.encode(commits, forKey: .commits)
    try c.encode(gateRun, forKey: .gateRun)
    try c.encode(mergeGateRun, forKey: .mergeGateRun)
    try c.encode(createdAt, forKey: .createdAt)
    try c.encode(mergedAt, forKey: .mergedAt)
    try c.encode(brief, forKey: .brief)
    try c.encode(tokens, forKey: .tokens)
  }
}

extension RunView.Span {
  private enum CodingKeys: String, CodingKey {
    case id, parent, phase, task, gateRun, start, end, outcome, approximate, tools
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(parent, forKey: .parent)
    try c.encode(phase, forKey: .phase)
    try c.encode(task, forKey: .task)
    try c.encode(gateRun, forKey: .gateRun)
    try c.encode(start, forKey: .start)
    try c.encode(end, forKey: .end)
    try c.encode(outcome, forKey: .outcome)
    try c.encode(approximate, forKey: .approximate)
    try c.encode(tools, forKey: .tools)
  }
}

extension RunView.GateStepRow {
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(tier, forKey: .tier)
    try c.encode(step, forKey: .step)
    try c.encode(startMs, forKey: .startMs)
    try c.encode(milliseconds, forKey: .milliseconds)
    try c.encode(verdict, forKey: .verdict)
  }
}

extension RunView.Gate {
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(runID, forKey: .runID)
    try c.encode(task, forKey: .task)
    try c.encode(command, forKey: .command)
    try c.encode(verdict, forKey: .verdict)
    try c.encode(milliseconds, forKey: .milliseconds)
    try c.encode(tests, forKey: .tests)
    try c.encode(ruleCounts, forKey: .ruleCounts)
    try c.encode(steps, forKey: .steps)
  }
}

extension RunView.Proof {
  private enum CodingKeys: String, CodingKey {
    case gateRun, task, test, outcome, proofBase, assertion
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(gateRun, forKey: .gateRun)
    try c.encode(task, forKey: .task)
    try c.encode(test, forKey: .test)
    try c.encode(outcome, forKey: .outcome)
    try c.encode(proofBase, forKey: .proofBase)
    try c.encode(assertion, forKey: .assertion)
  }
}

extension RunView.Halt {
  private enum CodingKeys: String, CodingKey {
    case task, reason, at, answer, waitMs
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(task, forKey: .task)
    try c.encode(reason, forKey: .reason)
    try c.encode(at, forKey: .at)
    try c.encode(answer, forKey: .answer)
    try c.encode(waitMs, forKey: .waitMs)
  }
}

/// `RunView` as JSON: sorted keys, ISO 8601 times with milliseconds, and `null` for every absent
/// value, so the page reads 1 spelling of "not known".
public enum RunViewJSON {
  public static func encode(_ view: RunView) throws -> Data {
    try encoder.encode(view)
  }

  /// A live poll's answer, in the same spelling as a whole view.
  public static func encode(_ changes: RunViewChanges) throws -> Data {
    try encoder.encode(changes)
  }

  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(date.formatted(HarnessEventJSON.timeFormat))
    }
    return encoder
  }
}

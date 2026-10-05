import Foundation

/// One build run's files under a plan's shared state (spec §4):
/// `<plan dir>/build/<run id>/{run.json, events.jsonl}`. Pure path arithmetic.
public struct BuildRunLayout: Sendable, Equatable {
  public let runID: String
  public let directory: String

  public var runFile: String { directory + "/run.json" }
  public var eventsFile: String { directory + "/events.jsonl" }
  /// `returns/`, each checked task return, which dependents' context packs read notes from.
  public var returnsDirectory: String { directory + "/returns" }

  /// `returns/<task>.json`; `task` must be a single safe path component.
  public func returnFile(task: String) -> String { returnsDirectory + "/\(task).json" }
}

public enum BuildRunLayoutError: Error, Sendable, Equatable {
  case invalidRunID(String)
}

extension PlanStateLayout.Plan {
  /// `<plan dir>/build`, the parent of every run of this plan.
  public var buildDirectory: String { directory + "/build" }

  /// - Throws: ``BuildRunLayoutError/invalidRunID(_:)`` for an id that isn't a single safe path
  ///   component, since it would address another run's or another plan's files.
  public func buildRun(_ runID: String) throws(BuildRunLayoutError) -> BuildRunLayout {
    guard RunID.isValid(runID), runID != ".", runID != ".." else { throw .invalidRunID(runID) }
    return BuildRunLayout(runID: runID, directory: buildDirectory + "/" + runID)
  }
}

/// `run.json`: what a build run started with. Written once when the run is created and never
/// rewritten, so later commands read the preset the run actually used, not the config's current one.
public struct BuildRunRecord: Sendable, Equatable {
  public static let schemaVersion = 1

  public let runID: String
  public let plan: String
  public let startedAt: Date
  public let presetName: String
  public let preset: BuildPreset
  /// A `swiftgate run`'s time box, which replaces the preset's budget fields for this run and
  /// measures from the run's launch, not from ``startedAt``. `nil` for every owned run.
  public let timeBox: RunTimeBox?
  /// Whether `build finish` records this run's end as a `finish` event in its ledger log, so the
  /// run hasn't ended until that event is the log's newest. `false` for a record a binary wrote
  /// before the event existed, whose run ends at its GREEN final gate instead.
  public let endsAtFinish: Bool

  public init(
    runID: String, plan: String, startedAt: Date, presetName: String, preset: BuildPreset,
    timeBox: RunTimeBox? = nil, endsAtFinish: Bool = true
  ) {
    self.runID = runID
    self.plan = plan
    self.startedAt = startedAt
    self.presetName = presetName
    self.preset = preset
    self.timeBox = timeBox
    self.endsAtFinish = endsAtFinish
  }

  /// After it, no new work starts: the box's, or the preset's budget less its stop margin from
  /// ``startedAt``; `nil` for a run with neither.
  public var noNewStartsAt: Date? {
    if let timeBox { return timeBox.deadlines.noNewStartsAt }
    guard preset.timeBudgetMin > 0 else { return nil }
    return startedAt.addingTimeInterval(
      TimeInterval((preset.timeBudgetMin - preset.stopStartsBeforeMin) * 60))
  }

  /// The box's cutoff, or the preset's budget from ``startedAt``; `nil` for a run with neither.
  public var cutoffAt: Date? {
    if let timeBox { return timeBox.deadlines.cutoffAt }
    guard preset.timeBudgetMin > 0 else { return nil }
    return startedAt.addingTimeInterval(TimeInterval(preset.timeBudgetMin * 60))
  }
}

extension BuildRunRecord: Codable {
  private enum CodingKeys: String, CodingKey {
    case schemaVersion, runId, plan, startedAt, presetName, preset, timeBox, endsAtFinish
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .schemaVersion)
    guard version == Self.schemaVersion else {
      throw DecodingError.dataCorruptedError(
        forKey: .schemaVersion, in: container,
        debugDescription: "unsupported run.json schemaVersion \(version)")
    }
    self.init(
      runID: try container.decode(String.self, forKey: .runId),
      plan: try container.decode(String.self, forKey: .plan),
      startedAt: try container.decode(Date.self, forKey: .startedAt),
      presetName: try container.decode(String.self, forKey: .presetName),
      preset: try container.decode(BuildPreset.self, forKey: .preset),
      timeBox: try container.decodeIfPresent(RunTimeBox.self, forKey: .timeBox),
      endsAtFinish: try container.decodeIfPresent(Bool.self, forKey: .endsAtFinish) ?? false)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.schemaVersion, forKey: .schemaVersion)
    try container.encode(runID, forKey: .runId)
    try container.encode(plan, forKey: .plan)
    try container.encode(startedAt, forKey: .startedAt)
    try container.encode(presetName, forKey: .presetName)
    try container.encode(preset, forKey: .preset)
    try container.encodeIfPresent(timeBox, forKey: .timeBox)
    if endsAtFinish { try container.encode(endsAtFinish, forKey: .endsAtFinish) }
  }
}

/// A preset's values under the same closed strings the `[build.presets.<name>]` table accepts, so
/// an unknown value fails decoding and names itself.
extension BuildPreset: Codable {
  private enum CodingKeys: String, CodingKey {
    case designTier, maxParallel, review, taskGate, mergeGate, workerModel, timeBudgetMin
    case stopStartsBeforeMin, onDesignConflict, taskProof, stallMin
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    func closed<Value: RawRepresentable>(_ key: CodingKeys) throws -> Value
    where Value.RawValue == String {
      let raw = try container.decode(String.self, forKey: key)
      guard let value = Value(rawValue: raw) else {
        throw DecodingError.dataCorruptedError(
          forKey: key, in: container, debugDescription: "unknown \(key.stringValue) '\(raw)'")
      }
      return value
    }
    let rawTaskGate = try container.decode(String.self, forKey: .taskGate)
    guard let taskGate = TaskGate(rawValue: rawTaskGate) else {
      throw DecodingError.dataCorruptedError(
        forKey: .taskGate, in: container, debugDescription: "unknown taskGate '\(rawTaskGate)'")
    }
    self.init(
      designTier: try closed(.designTier),
      maxParallel: try container.decode(Int.self, forKey: .maxParallel),
      review: try closed(.review),
      taskGate: taskGate,
      mergeGate: try closed(.mergeGate),
      workerModel: try closed(.workerModel),
      timeBudgetMin: try container.decode(Int.self, forKey: .timeBudgetMin),
      stopStartsBeforeMin: try container.decode(Int.self, forKey: .stopStartsBeforeMin),
      onDesignConflict: try closed(.onDesignConflict),
      // A run started before the key existed proved every task in its own gate.
      taskProof: container.contains(.taskProof) ? try closed(.taskProof) : .perTask,
      stallMin: try container.decodeIfPresent(Int.self, forKey: .stallMin))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(designTier.rawValue, forKey: .designTier)
    try container.encode(maxParallel, forKey: .maxParallel)
    try container.encode(review.rawValue, forKey: .review)
    let taskGateRaw: String
    switch taskGate {
    case .ledger: taskGateRaw = "ledger"
    case .tier(let tier): taskGateRaw = tier.rawValue
    }
    try container.encode(taskGateRaw, forKey: .taskGate)
    try container.encode(mergeGate.rawValue, forKey: .mergeGate)
    try container.encode(workerModel.rawValue, forKey: .workerModel)
    try container.encode(timeBudgetMin, forKey: .timeBudgetMin)
    try container.encode(stopStartsBeforeMin, forKey: .stopStartsBeforeMin)
    try container.encode(onDesignConflict.rawValue, forKey: .onDesignConflict)
    try container.encode(taskProof.rawValue, forKey: .taskProof)
    try container.encodeIfPresent(stallMin, forKey: .stallMin)
  }
}

/// One line of `events.jsonl`. The `kind` key is closed: a line of any other kind fails decoding.
public enum BuildEvent: Sendable, Equatable {
  case transition(Transition)
  case merge(Merge)
  case undo(Undo)
  case gate(Gate)
  case returnCheck(ReturnCheck)
  case finish(Finish)
  case rowsUnverified(RowsUnverified)

  public struct Transition: Sendable, Equatable {
    public let task: String
    public let from: TaskStatus
    public let to: TaskStatus
    public let at: Date

    public init(task: String, from: TaskStatus, to: TaskStatus, at: Date) {
      self.task = task
      self.from = from
      self.to = to
      self.at = at
    }
  }

  /// `preCommit` is `main` before the merge, which `build merge --undo` resets to;
  /// `postCommit` is `main` after it.
  public struct Merge: Sendable, Equatable {
    public let task: String
    public let preCommit: String
    public let postCommit: String
    public let at: Date
    /// The other tasks whose unmerged branches this merge landed: a fixer's branch that took
    /// them in for a RED run over them all. Each counts as merged by this merge.
    public let carried: [String]

    public init(
      task: String, preCommit: String, postCommit: String, at: Date, carried: [String] = []
    ) {
      self.task = task
      self.preCommit = preCommit
      self.postCommit = postCommit
      self.at = at
      self.carried = carried
    }
  }

  /// `build merge --undo` moved `main` from `fromCommit`, the undone merge's post commit, back
  /// to `toCommit`, its pre commit.
  public struct Undo: Sendable, Equatable {
    public let task: String
    public let fromCommit: String
    public let toCommit: String
    public let at: Date

    public init(task: String, fromCommit: String, toCommit: String, at: Date) {
      self.task = task
      self.fromCommit = fromCommit
      self.toCommit = toCommit
      self.at = at
    }
  }

  /// A `swiftgate check` the orchestrator ran on `main`: the merge gate after a task's merge, or
  /// the final gate. `build record-gate` reads its tier and verdict from the run's own report.
  public struct Gate: Sendable, Equatable {
    public enum Stage: Sendable, Equatable {
      case merge(task: String)
      case final
    }

    public let stage: Stage
    public let tier: CheckTier
    public let verdict: Verdict
    public let runID: String
    public let at: Date

    public init(stage: Stage, tier: CheckTier, verdict: Verdict, runID: String, at: Date) {
      self.stage = stage
      self.tier = tier
      self.verdict = verdict
      self.runID = runID
      self.at = at
    }
  }

  /// `build check-return`'s verdict on 1 task's return, which `build merge` requires GREEN at
  /// the commit it merges.
  public struct ReturnCheck: Sendable, Equatable {
    public let task: String
    /// A fixer's return, checked with `--fix`.
    public let fix: Bool
    public let verdict: Verdict
    /// The full sha of the return's last commit; `nil` when it named none git knows.
    public let commit: String?
    /// The id the check's `build.return-checked` event carries too.
    public let checkID: String
    /// Every finding's rule, each once, in report order.
    public let rules: [TaskReturnFinding.Rule]
    public let at: Date
    /// The checked return's outcome; `nil` when the recorded check names none.
    public let outcome: TaskReturn.Outcome?

    public init(
      task: String, fix: Bool, verdict: Verdict, commit: String?, checkID: String,
      rules: [TaskReturnFinding.Rule], at: Date, outcome: TaskReturn.Outcome? = nil
    ) {
      self.task = task
      self.fix = fix
      self.verdict = verdict
      self.commit = commit
      self.checkID = checkID
      self.rules = rules
      self.at = at
      self.outcome = outcome
    }
  }

  /// `build finish` closed the run. A ledger event after it means the build resumed.
  public struct Finish: Sendable, Equatable {
    public let at: Date
    /// The `qa run --final` whose verdict the finish read; `nil` for a plan with no validation
    /// table.
    public let qaRun: String?
    /// That run's verdict.
    public let validation: Verdict?

    public init(at: Date, qaRun: String? = nil, validation: Verdict? = nil) {
      self.at = at
      self.qaRun = qaRun
      self.validation = validation
    }
  }

  /// `build no-repair` decided that a task merges with these validation rows left unverified:
  /// the flow repair found no repair for them, and every other row of the run passed. `build
  /// merge` then takes a run red on these rows alone, and the final `qa run` reports them
  /// `unverified` without running them.
  public struct RowsUnverified: Sendable, Equatable {
    public enum Cause: String, Sendable, Codable {
      case contractGap = "contract-gap"
      case appAtFault = "app-at-fault"
    }

    public let task: String
    public let requirement: String
    /// 1-based positions in `validation.json`'s `rows`.
    public let rows: [Int]
    /// The before-merge `qa run` the rows were red in.
    public let qaRun: String
    public let cause: Cause
    /// The contract name a `contract-gap` row needs; `nil` when the return named none.
    public let contractName: String?
    public let at: Date

    public init(
      task: String, requirement: String, rows: [Int], qaRun: String, cause: Cause,
      contractName: String? = nil, at: Date
    ) {
      self.task = task
      self.requirement = requirement
      self.rows = rows
      self.qaRun = qaRun
      self.cause = cause
      self.contractName = contractName
      self.at = at
    }
  }

  public enum Kind: String, Sendable, Codable, CaseIterable {
    case transition, merge, undo, gate
    case returnCheck = "return-check"
    case finish
    case rowsUnverified = "rows-unverified"
  }

  public var kind: Kind {
    switch self {
    case .transition: .transition
    case .merge: .merge
    case .undo: .undo
    case .gate: .gate
    case .returnCheck: .returnCheck
    case .finish: .finish
    case .rowsUnverified: .rowsUnverified
    }
  }

  /// `nil` for the final gate and the finish, which belong to no task.
  public var task: String? {
    switch self {
    case .transition(let transition): transition.task
    case .merge(let merge): merge.task
    case .undo(let undo): undo.task
    case .gate(let gate):
      switch gate.stage {
      case .merge(let task): task
      case .final: nil
      }
    case .returnCheck(let check): check.task
    case .finish: nil
    case .rowsUnverified(let left): left.task
    }
  }
}

extension BuildEvent: Codable {
  private enum CodingKeys: String, CodingKey {
    case kind, task, from, to, preCommit, postCommit, fromCommit, toCommit, at, gate, tier, verdict
    case fix, commit, rules, qaRun, validation, outcome, carried
    case requirement, rows, cause, contractName
    case runID = "runId"
    case checkID = "checkId"
  }

  private enum GateStage: String, Codable {
    case merge, final
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let at = try container.decode(Date.self, forKey: .at)
    func task() throws -> String { try container.decode(String.self, forKey: .task) }
    switch try container.decode(Kind.self, forKey: .kind) {
    case .transition:
      self = .transition(
        Transition(
          task: try task(), from: try container.decode(TaskStatus.self, forKey: .from),
          to: try container.decode(TaskStatus.self, forKey: .to), at: at))
    case .merge:
      self = .merge(
        Merge(
          task: try task(), preCommit: try container.decode(String.self, forKey: .preCommit),
          postCommit: try container.decode(String.self, forKey: .postCommit), at: at,
          carried: try container.decodeIfPresent([String].self, forKey: .carried) ?? []))
    case .undo:
      self = .undo(
        Undo(
          task: try task(), fromCommit: try container.decode(String.self, forKey: .fromCommit),
          toCommit: try container.decode(String.self, forKey: .toCommit), at: at))
    case .gate:
      let stage: Gate.Stage =
        switch try container.decode(GateStage.self, forKey: .gate) {
        case .merge: .merge(task: try task())
        case .final: .final
        }
      self = .gate(
        Gate(
          stage: stage, tier: try container.decode(CheckTier.self, forKey: .tier),
          verdict: try container.decode(Verdict.self, forKey: .verdict),
          runID: try container.decode(String.self, forKey: .runID), at: at))
    case .returnCheck:
      self = .returnCheck(
        ReturnCheck(
          task: try task(), fix: try container.decode(Bool.self, forKey: .fix),
          verdict: try container.decode(Verdict.self, forKey: .verdict),
          commit: try container.decodeIfPresent(String.self, forKey: .commit),
          checkID: try container.decode(String.self, forKey: .checkID),
          rules: try container.decode([TaskReturnFinding.Rule].self, forKey: .rules), at: at,
          outcome: try container.decodeIfPresent(TaskReturn.Outcome.self, forKey: .outcome)))
    case .finish:
      self = .finish(
        Finish(
          at: at, qaRun: try container.decodeIfPresent(String.self, forKey: .qaRun),
          validation: try container.decodeIfPresent(Verdict.self, forKey: .validation)))
    case .rowsUnverified:
      self = .rowsUnverified(
        RowsUnverified(
          task: try task(), requirement: try container.decode(String.self, forKey: .requirement),
          rows: try container.decode([Int].self, forKey: .rows),
          qaRun: try container.decode(String.self, forKey: .qaRun),
          cause: try container.decode(RowsUnverified.Cause.self, forKey: .cause),
          contractName: try container.decodeIfPresent(String.self, forKey: .contractName), at: at))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(kind, forKey: .kind)
    switch self {
    case .transition(let transition):
      try container.encode(transition.task, forKey: .task)
      try container.encode(transition.from, forKey: .from)
      try container.encode(transition.to, forKey: .to)
      try container.encode(transition.at, forKey: .at)
    case .merge(let merge):
      try container.encode(merge.task, forKey: .task)
      try container.encode(merge.preCommit, forKey: .preCommit)
      try container.encode(merge.postCommit, forKey: .postCommit)
      try container.encode(merge.at, forKey: .at)
      if !merge.carried.isEmpty { try container.encode(merge.carried, forKey: .carried) }
    case .undo(let undo):
      try container.encode(undo.task, forKey: .task)
      try container.encode(undo.fromCommit, forKey: .fromCommit)
      try container.encode(undo.toCommit, forKey: .toCommit)
      try container.encode(undo.at, forKey: .at)
    case .gate(let gate):
      switch gate.stage {
      case .merge(let task):
        try container.encode(GateStage.merge, forKey: .gate)
        try container.encode(task, forKey: .task)
      case .final:
        try container.encode(GateStage.final, forKey: .gate)
      }
      try container.encode(gate.tier, forKey: .tier)
      try container.encode(gate.verdict, forKey: .verdict)
      try container.encode(gate.runID, forKey: .runID)
      try container.encode(gate.at, forKey: .at)
    case .returnCheck(let check):
      try container.encode(check.task, forKey: .task)
      try container.encode(check.fix, forKey: .fix)
      try container.encode(check.verdict, forKey: .verdict)
      try container.encodeIfPresent(check.commit, forKey: .commit)
      try container.encode(check.checkID, forKey: .checkID)
      try container.encode(check.rules, forKey: .rules)
      try container.encode(check.at, forKey: .at)
      try container.encodeIfPresent(check.outcome, forKey: .outcome)
    case .finish(let finish):
      try container.encodeIfPresent(finish.qaRun, forKey: .qaRun)
      try container.encodeIfPresent(finish.validation, forKey: .validation)
      try container.encode(finish.at, forKey: .at)
    case .rowsUnverified(let left):
      try container.encode(left.task, forKey: .task)
      try container.encode(left.requirement, forKey: .requirement)
      try container.encode(left.rows, forKey: .rows)
      try container.encode(left.qaRun, forKey: .qaRun)
      try container.encode(left.cause, forKey: .cause)
      try container.encodeIfPresent(left.contractName, forKey: .contractName)
      try container.encode(left.at, forKey: .at)
    }
  }
}

/// `events.jsonl` read back: every event that decoded, in file order, plus each line that didn't.
/// Damage is reported, never dropped, so a reader decides whether a partial log is usable.
public struct BuildEventLog: Sendable, Equatable {
  public enum Damage: Sendable, Equatable {
    /// The file doesn't end in a newline: its last write never finished. `line` is 1-based.
    case tornLastLine(line: Int)
    /// A complete line that isn't a ``BuildEvent``. `line` is 1-based.
    case undecodableLine(line: Int, reason: String)
  }

  public let events: [BuildEvent]
  public let damage: [Damage]

  public init(events: [BuildEvent], damage: [Damage]) {
    self.events = events
    self.damage = damage
  }

  /// Where `main` should be now: the newest merge's post commit, or the newest undo's
  /// `toCommit` when the undo came later; `nil` before the run's first merge.
  public var lastMergePostCommit: String? {
    for event in events.reversed() {
      switch event {
      case .merge(let merge): return merge.postCommit
      case .undo(let undo): return undo.toCommit
      case .transition, .gate, .returnCheck, .finish, .rowsUnverified: continue
      }
    }
    return nil
  }

  /// The tasks on `main`, in the order they reached it: an undo takes its task back off, and a
  /// later merge of the same task puts it back at the end.
  public var mergedTasks: [String] {
    var tasks: [String] = []
    var carriedBy: [String: [String]] = [:]
    for event in events {
      switch event {
      case .merge(let merge):
        let landed = [merge.task] + merge.carried
        tasks.removeAll { landed.contains($0) }
        tasks += landed
        carriedBy[merge.task] = merge.carried
      case .undo(let undo):
        let gone = [undo.task] + (carriedBy[undo.task] ?? [])
        tasks.removeAll { gone.contains($0) }
      case .transition, .gate, .returnCheck, .finish, .rowsUnverified: continue
      }
    }
    return tasks
  }

  /// Whether a `final` gate is recorded after the newest merge or undo: the build has ended, so
  /// no later merge can make a validation row ready.
  public var finalGated: Bool {
    for event in events.reversed() {
      switch event {
      case .gate(let gate):
        if case .final = gate.stage { return true }
      case .merge, .undo: return false
      case .transition, .returnCheck, .finish, .rowsUnverified: continue
      }
    }
    return false
  }

  /// How far `task`'s merge got: `nil` when it isn't on `main`, ``CutoffTaskStage/landed`` once a
  /// GREEN merge gate is recorded after its newest merge, and ``CutoffTaskStage/merged`` before.
  public func mergeStage(task: String) -> CutoffTaskStage? {
    var stage: CutoffTaskStage?
    // The task whose merge put this one on `main`: itself, or the fix that carried it.
    var landedBy = task
    for event in events {
      switch event {
      case .merge(let merge) where merge.task == task || merge.carried.contains(task):
        stage = .merged
        landedBy = merge.task
      case .undo(let undo) where undo.task == landedBy: stage = nil
      case .gate(let gate):
        guard case .merge(let gated) = gate.stage, gated == landedBy, stage != nil else {
          continue
        }
        stage = gate.verdict == .green ? .landed : .merged
      case .merge, .undo, .transition, .returnCheck, .finish, .rowsUnverified: continue
      }
    }
    return stage
  }

  /// Each validation row a `build no-repair` decision left unverified, by its 1-based position,
  /// with the newest decision that names it.
  public func unverifiedRows() -> [Int: BuildEvent.RowsUnverified] {
    var rows: [Int: BuildEvent.RowsUnverified] = [:]
    for event in events {
      guard case .rowsUnverified(let left) = event else { continue }
      for row in left.rows { rows[row] = left }
    }
    return rows
  }

  /// The newest `build check-return` verdict on `task`'s return, or with `fix` on its fixer's;
  /// `nil` when none was recorded.
  public func latestReturnCheck(task: String, fix: Bool) -> BuildEvent.ReturnCheck? {
    for event in events.reversed() {
      if case .returnCheck(let check) = event, check.task == task, check.fix == fix {
        return check
      }
    }
    return nil
  }
}

public enum BuildEventJSON {
  public static func encodeLine(_ event: BuildEvent) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    var data = try encoder.encode(event)
    data.append(UInt8(ascii: "\n"))
    return data
  }

  public static func decode(_ data: Data) -> BuildEventLog {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
    let isTorn = data.last.map { $0 != UInt8(ascii: "\n") } ?? false
    if !isTorn { lines.removeLast() }
    var events: [BuildEvent] = []
    var damage: [BuildEventLog.Damage] = []
    for (offset, line) in lines.enumerated() {
      let number = offset + 1
      if isTorn, offset == lines.count - 1 {
        damage.append(.tornLastLine(line: number))
        continue
      }
      do {
        events.append(try decoder.decode(BuildEvent.self, from: Data(line)))
      } catch {
        damage.append(.undecodableLine(line: number, reason: String(describing: error)))
      }
    }
    return BuildEventLog(events: events, damage: damage)
  }
}

public enum BuildRunJSON {
  public static func encode(_ record: BuildRunRecord) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    var data = try encoder.encode(record)
    data.append(UInt8(ascii: "\n"))
    return data
  }

  public static func decode(_ data: Data) throws -> BuildRunRecord {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(BuildRunRecord.self, from: data)
  }
}

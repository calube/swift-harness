import Foundation

/// One build run's files under a plan's shared state (spec §4):
/// `<plan dir>/build/<run id>/{run.json, events.jsonl}`. Pure path arithmetic.
public struct BuildRunLayout: Sendable, Equatable {
  public let runID: String
  public let directory: String

  public var runFile: String { directory + "/run.json" }
  public var eventsFile: String { directory + "/events.jsonl" }
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

  public init(
    runID: String, plan: String, startedAt: Date, presetName: String, preset: BuildPreset,
    timeBox: RunTimeBox? = nil
  ) {
    self.runID = runID
    self.plan = plan
    self.startedAt = startedAt
    self.presetName = presetName
    self.preset = preset
    self.timeBox = timeBox
  }
}

extension BuildRunRecord: Codable {
  private enum CodingKeys: String, CodingKey {
    case schemaVersion, runId, plan, startedAt, presetName, preset, timeBox
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
      timeBox: try container.decodeIfPresent(RunTimeBox.self, forKey: .timeBox))
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

    public init(task: String, preCommit: String, postCommit: String, at: Date) {
      self.task = task
      self.preCommit = preCommit
      self.postCommit = postCommit
      self.at = at
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

    public init(
      task: String, fix: Bool, verdict: Verdict, commit: String?, checkID: String,
      rules: [TaskReturnFinding.Rule], at: Date
    ) {
      self.task = task
      self.fix = fix
      self.verdict = verdict
      self.commit = commit
      self.checkID = checkID
      self.rules = rules
      self.at = at
    }
  }

  public enum Kind: String, Sendable, Codable, CaseIterable {
    case transition, merge, undo, gate
    case returnCheck = "return-check"
  }

  public var kind: Kind {
    switch self {
    case .transition: .transition
    case .merge: .merge
    case .undo: .undo
    case .gate: .gate
    case .returnCheck: .returnCheck
    }
  }

  /// `nil` for the final gate, which belongs to no task.
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
    }
  }
}

extension BuildEvent: Codable {
  private enum CodingKeys: String, CodingKey {
    case kind, task, from, to, preCommit, postCommit, fromCommit, toCommit, at, gate, tier, verdict
    case fix, commit, rules
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
          postCommit: try container.decode(String.self, forKey: .postCommit), at: at))
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
          rules: try container.decode([TaskReturnFinding.Rule].self, forKey: .rules), at: at))
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
      case .transition, .gate, .returnCheck: continue
      }
    }
    return nil
  }

  /// The tasks on `main`, in the order they reached it: an undo takes its task back off, and a
  /// later merge of the same task puts it back at the end.
  public var mergedTasks: [String] {
    var tasks: [String] = []
    for event in events {
      switch event {
      case .merge(let merge):
        tasks.removeAll { $0 == merge.task }
        tasks.append(merge.task)
      case .undo(let undo): tasks.removeAll { $0 == undo.task }
      case .transition, .gate, .returnCheck: continue
      }
    }
    return tasks
  }

  /// How far `task`'s merge got: `nil` when it isn't on `main`, ``CutoffTaskStage/landed`` once a
  /// GREEN merge gate is recorded after its newest merge, and ``CutoffTaskStage/merged`` before.
  public func mergeStage(task: String) -> CutoffTaskStage? {
    nil
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

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

  public init(runID: String, plan: String, startedAt: Date, presetName: String, preset: BuildPreset)
  {
    self.runID = runID
    self.plan = plan
    self.startedAt = startedAt
    self.presetName = presetName
    self.preset = preset
  }
}

extension BuildRunRecord: Codable {
  private enum CodingKeys: String, CodingKey {
    case schemaVersion, runId, plan, startedAt, presetName, preset
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
      preset: try container.decode(BuildPreset.self, forKey: .preset))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.schemaVersion, forKey: .schemaVersion)
    try container.encode(runID, forKey: .runId)
    try container.encode(plan, forKey: .plan)
    try container.encode(startedAt, forKey: .startedAt)
    try container.encode(presetName, forKey: .presetName)
    try container.encode(preset, forKey: .preset)
  }
}

/// A preset's values under the same closed strings the `[build.presets.<name>]` table accepts, so
/// an unknown value fails decoding and names itself.
extension BuildPreset: Codable {
  private enum CodingKeys: String, CodingKey {
    case designTier, maxParallel, review, taskGate, mergeGate, workerModel, timeBudgetMin
    case stopStartsBeforeMin, onDesignConflict
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
      onDesignConflict: try closed(.onDesignConflict))
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
  }
}

/// One line of `events.jsonl`. The `kind` key is closed: a line of any other kind fails decoding.
public enum BuildEvent: Sendable, Equatable {
  case transition(Transition)
  case merge(Merge)

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

  public enum Kind: String, Sendable, Codable, CaseIterable {
    case transition, merge
  }

  public var kind: Kind {
    switch self {
    case .transition: .transition
    case .merge: .merge
    }
  }

  public var task: String {
    switch self {
    case .transition(let transition): transition.task
    case .merge(let merge): merge.task
    }
  }
}

extension BuildEvent: Codable {
  private enum CodingKeys: String, CodingKey {
    case kind, task, from, to, preCommit, postCommit, at
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let task = try container.decode(String.self, forKey: .task)
    let at = try container.decode(Date.self, forKey: .at)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .transition:
      self = .transition(
        Transition(
          task: task, from: try container.decode(TaskStatus.self, forKey: .from),
          to: try container.decode(TaskStatus.self, forKey: .to), at: at))
    case .merge:
      self = .merge(
        Merge(
          task: task, preCommit: try container.decode(String.self, forKey: .preCommit),
          postCommit: try container.decode(String.self, forKey: .postCommit), at: at))
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

  /// The post commit of the newest merge, which is where `main` should be now; `nil` before the
  /// run's first merge.
  public var lastMergePostCommit: String? {
    for event in events.reversed() {
      if case .merge(let merge) = event { return merge.postCommit }
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

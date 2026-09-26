import Foundation

/// A `LedgerTask.status` value (spec §5.7): the closed set of states this sub-project defines.
/// `ledger.json` is written by the trusted orchestrator, not a worker, but the set is still closed
/// deliberately — a status this build doesn't know is a schema change that should fail loudly, not
/// a value to carry through unexamined. `done` tasks are immutable — enforcing that is the
/// writer's job, not this type's.
public enum TaskStatus: String, Sendable, Equatable, Codable, CaseIterable {
  case pending
  case inProgress = "in-progress"
  case done
  case needsReplan = "needs-replan"
}

/// One `ledger.json` task entry (spec §5.7).
public struct LedgerTask: Sendable, Equatable {
  public let id: String
  public let deps: [String]
  /// Exact paths or `/`-terminated prefixes (``WriteSet``).
  public let writeSet: [String]
  public let gate: CheckTier
  public let tests: [String]
  public let covers: [String]
  public let estLines: Int
  public let status: TaskStatus
  public let worktree: String
  /// The task's real line count, once sub-project 5's worker report writes it. `nil` until then —
  /// never a placeholder `0` (`stats`' estimate error, spec §9.3, excludes a task without one).
  public let actualLines: Int?

  public init(
    id: String, deps: [String], writeSet: [String], gate: CheckTier, tests: [String],
    covers: [String], estLines: Int, status: TaskStatus, worktree: String,
    actualLines: Int? = nil
  ) {
    self.id = id
    self.deps = deps
    self.writeSet = writeSet
    self.gate = gate
    self.tests = tests
    self.covers = covers
    self.estLines = estLines
    self.status = status
    self.worktree = worktree
    self.actualLines = actualLines
  }
}

extension LedgerTask: Codable {
  private enum CodingKeys: String, CodingKey {
    case id, deps, writeSet, gate, tests, covers, estLines, status, worktree, actualLines
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let id = try c.decode(String.self, forKey: .id)
    let actualLines = try c.decodeIfPresent(Int.self, forKey: .actualLines)
    if let actualLines, actualLines < 0 {
      throw DecodingError.dataCorruptedError(
        forKey: .actualLines, in: c,
        debugDescription: "task `\(id)`: actualLines must not be negative")
    }
    self.init(
      id: id, deps: try c.decode([String].self, forKey: .deps),
      writeSet: try c.decode([String].self, forKey: .writeSet),
      gate: try c.decode(CheckTier.self, forKey: .gate),
      tests: try c.decode([String].self, forKey: .tests),
      covers: try c.decode([String].self, forKey: .covers),
      estLines: try c.decode(Int.self, forKey: .estLines),
      status: try c.decode(TaskStatus.self, forKey: .status),
      worktree: try c.decode(String.self, forKey: .worktree), actualLines: actualLines)
  }

  /// `actualLines` is omitted entirely when `nil`, so an existing ledger with no notion of it
  /// round-trips byte-stable.
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(deps, forKey: .deps)
    try c.encode(writeSet, forKey: .writeSet)
    try c.encode(gate, forKey: .gate)
    try c.encode(tests, forKey: .tests)
    try c.encode(covers, forKey: .covers)
    try c.encode(estLines, forKey: .estLines)
    try c.encode(status, forKey: .status)
    try c.encode(worktree, forKey: .worktree)
    try c.encodeIfPresent(actualLines, forKey: .actualLines)
  }
}

/// `.harness/plans/<slug>/ledger.json` (spec §5.7): tasks and their wave schedule.
public struct Ledger: Sendable, Equatable, Codable {
  public let schemaVersion: Int
  public let resume: String
  public let maxParallel: Int
  public let tasks: [LedgerTask]
  /// Must equal `plan-schedule`'s recomputed output; a hand edit here fails `plan-lint` (spec
  /// §9.2).
  public let waves: [[String]]

  public init(
    schemaVersion: Int, resume: String, maxParallel: Int, tasks: [LedgerTask], waves: [[String]]
  ) {
    self.schemaVersion = schemaVersion
    self.resume = resume
    self.maxParallel = maxParallel
    self.tasks = tasks
    self.waves = waves
  }
}

/// Encodes `ledger.json` as one pretty-printed, key-sorted object, so two encodes of the same
/// value produce identical bytes (the file is reviewed as a diff).
public enum LedgerJSON {
  public static func encode(_ ledger: Ledger) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(ledger)
    data.append(UInt8(ascii: "\n"))
    return data
  }

  public static func decode(_ data: Data) throws -> Ledger {
    try JSONDecoder().decode(Ledger.self, from: data)
  }
}

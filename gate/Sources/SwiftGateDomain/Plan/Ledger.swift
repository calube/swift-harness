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
public struct LedgerTask: Sendable, Equatable, Codable {
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

  public init(
    id: String, deps: [String], writeSet: [String], gate: CheckTier, tests: [String],
    covers: [String], estLines: Int, status: TaskStatus, worktree: String
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

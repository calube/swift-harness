import Foundation

/// A `LedgerTask.status` value (spec §5.7). `pending`/`inProgress`/`done`/`needsReplan` are the
/// states this sub-project defines; `.other` preserves whatever a later sub-project adds so an
/// older `swiftgate` build round-trips a ledger without dropping a status it doesn't know yet.
/// `done` tasks are immutable — enforcing that is the writer's job, not this type's.
public enum TaskStatus: Sendable, Equatable {
  case pending
  case inProgress
  case done
  case needsReplan
  case other(String)

  public var rawValue: String {
    switch self {
    case .pending: return "pending"
    case .inProgress: return "in-progress"
    case .done: return "done"
    case .needsReplan: return "needs-replan"
    case .other(let value): return value
    }
  }

  public init(rawValue: String) {
    switch rawValue {
    case "pending": self = .pending
    case "in-progress": self = .inProgress
    case "done": self = .done
    case "needs-replan": self = .needsReplan
    default: self = .other(rawValue)
    }
  }
}

extension TaskStatus: Codable {
  public init(from decoder: Decoder) throws {
    self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// One `ledger.json` task entry (spec §5.7).
public struct LedgerTask: Sendable, Equatable, Codable {
  public let id: String
  public let deps: [String]
  /// Exact paths or `/`-terminated prefixes (``WriteSet``).
  public let writeSet: [String]
  /// A `CheckTier` raw value (`fast`/`push`/`ready`). Kept as the wire string rather than
  /// `CheckTier` itself so this model doesn't add a retroactive `Codable` conformance to a type
  /// declared in a file other tasks still edit; `plan-lint` parses and compares it.
  public let gate: String
  public let tests: [String]
  public let covers: [String]
  public let estLines: Int
  public let status: TaskStatus
  public let worktree: String

  public init(
    id: String, deps: [String], writeSet: [String], gate: String, tests: [String],
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

import Foundation

/// A flow row rewritten after its flow, not the app, kept it red: a step the pinned tool can't
/// drive as written, such as a `scroll` where a pull to refresh needs a `gesture` drag. A
/// validation worker in repair mode rewrites only that requirement's checks and proves them red at
/// the merge base again; `qa adopt --repair` takes them into plan state only when these rules
/// pass, so a repair can't weaken a check into one that passes whatever the app shows.
public enum QAFlowRepair {
  /// Plan state's record of every repair, beside the adopted checks in `qa/`.
  public static let fileName = "repairs.json"

  public static let capRuleID = "qa.repair-cap"
  public static let outsideRowRuleID = "qa.repair-outside-row"
  public static let weakensRuleID = "qa.repair-weakens-check"
  public static let unchangedRuleID = "qa.repair-unchanged"
  public static let notRedRuleID = "qa.repair-not-red"
  public static let wrongRedRuleID = "qa.repair-wrong-red"
  public static let redRunsRuleID = "qa.repair-red-runs"

  /// Why the orchestrator sent the row to repair.
  public enum Cause: String, Sendable, Equatable, Codable, CaseIterable {
    /// The fixer judged the failing step the flow's fault.
    case flowSide = "flow-side"
    /// The row stayed red after a fixer's change to the app.
    case stillRed = "still-red"
  }

  /// 1 `qa run` that read the row red before the repair, with the requirement's flow row as that
  /// run's report holds it; `nil` when the report doesn't read or holds no such row.
  public struct RedRun: Sendable, Equatable {
    public let runID: String
    public let row: QARow?

    public init(runID: String, row: QARow?) {
      self.runID = runID
      self.row = row
    }
  }

  /// Everything the rules read for 1 repair.
  public struct Input: Sendable, Equatable {
    public let requirement: String
    /// The requirement's rows in `validation.json`, with their 1-based row numbers.
    public let rows: [(row: Int, validation: ValidationRow)]
    /// Each row's check file as plan state holds it, by check (`qa/<name>`).
    public let adopted: [String: Data]
    /// Each check file the prepared folder holds, by check (`qa/<name>`).
    public let repaired: [String: Data]
    /// The names of every file directly in the prepared folder.
    public let preparedFiles: [String]
    /// Plan state's `at-base-run.json`; `nil` when it doesn't read.
    public let adoptedRecord: QAAtBaseRun?
    /// The prepared folder's `at-base-run.json`; `nil` when it doesn't read.
    public let preparedRecord: QAAtBaseRun?
    public let redRuns: [RedRun]
    public let earlier: [QAFlowRepairRecord]
    public let buildRun: String

    public init(
      requirement: String, rows: [(row: Int, validation: ValidationRow)], adopted: [String: Data],
      repaired: [String: Data], preparedFiles: [String], adoptedRecord: QAAtBaseRun?,
      preparedRecord: QAAtBaseRun?, redRuns: [RedRun], earlier: [QAFlowRepairRecord],
      buildRun: String
    ) {
      self.requirement = requirement
      self.rows = rows
      self.adopted = adopted
      self.repaired = repaired
      self.preparedFiles = preparedFiles
      self.adoptedRecord = adoptedRecord
      self.preparedRecord = preparedRecord
      self.redRuns = redRuns
      self.earlier = earlier
      self.buildRun = buildRun
    }

    public static func == (lhs: Input, rhs: Input) -> Bool {
      lhs.requirement == rhs.requirement
        && lhs.rows.map(\.row) == rhs.rows.map(\.row)
        && lhs.rows.map(\.validation) == rhs.rows.map(\.validation)
        && lhs.adopted == rhs.adopted && lhs.repaired == rhs.repaired
        && lhs.preparedFiles == rhs.preparedFiles && lhs.adoptedRecord == rhs.adoptedRecord
        && lhs.preparedRecord == rhs.preparedRecord && lhs.redRuns == rhs.redRuns
        && lhs.earlier == rhs.earlier && lhs.buildRun == rhs.buildRun
    }
  }

  /// Each rule the repair breaks; empty when plan state may take it.
  public static func findings(_ input: Input) -> [Finding] {
    []
  }

  /// The step a red flow row's message names, as `step <n> \`<command>\` failed: …` writes it;
  /// `nil` for any other message.
  public static func failingStep(in message: String) -> (number: Int, command: String)? {
    nil
  }

  /// The commands of the steps the repair took out of the adopted flow and put in, by count, in
  /// the order each flow holds them.
  public static func changedCommands(adopted: Data, repaired: Data) -> (
    removed: [String], added: [String]
  ) {
    ([], [])
  }
}

/// 1 repair plan state took.
public struct QAFlowRepairRecord: Sendable, Equatable, Codable {
  public let requirement: String
  /// The 1-based rows of `validation.json` whose checks it replaced.
  public let rows: [Int]
  public let checks: [String]
  /// The build run it counts against: 1 repair per requirement per build run.
  public let buildRun: String
  public let cause: QAFlowRepair.Cause
  /// The orchestrator's words for why the flow, not the app, was at fault.
  public let reason: String
  public let redRuns: [String]
  /// The prepared run that proved the repaired checks red at the merge base.
  public let atBaseRun: String
  /// The step the red runs failed at, and its command.
  public let failingStep: Int?
  public let failingCommand: String?
  public let removed: [String]
  public let added: [String]

  public init(
    requirement: String, rows: [Int], checks: [String], buildRun: String,
    cause: QAFlowRepair.Cause, reason: String, redRuns: [String], atBaseRun: String,
    failingStep: Int?, failingCommand: String?, removed: [String], added: [String]
  ) {
    self.requirement = requirement
    self.rows = rows
    self.checks = checks
    self.buildRun = buildRun
    self.cause = cause
    self.reason = reason
    self.redRuns = redRuns
    self.atBaseRun = atBaseRun
    self.failingStep = failingStep
    self.failingCommand = failingCommand
    self.removed = removed
    self.added = added
  }
}

/// `qa/repairs.json`: every repair plan state took, oldest first.
public struct QAFlowRepairs: Sendable, Equatable, Codable {
  public static let currentSchemaVersion = 1

  public let schemaVersion: Int
  public let repairs: [QAFlowRepairRecord]

  public init(repairs: [QAFlowRepairRecord]) {
    self.schemaVersion = Self.currentSchemaVersion
    self.repairs = repairs
  }

  public static func decode(_ data: Data) throws -> QAFlowRepairs {
    let decoded = try JSONDecoder().decode(QAFlowRepairs.self, from: data)
    guard decoded.schemaVersion == currentSchemaVersion else {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: [], debugDescription: "unsupported schemaVersion \(decoded.schemaVersion)"))
    }
    return decoded
  }

  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(self)
    data.append(UInt8(ascii: "\n"))
    return data
  }
}

/// `qa.check`: 1 validation row in 1 `qa run`. Ids, closed values, counts and run-relative paths
/// only: the check's command and its output stay in the run's `qa/report.json`, joined by `row`.
public struct QACheckEvent: Sendable, Equatable, Codable {
  public let plan: String
  /// 1-based position in `validation.json`'s `rows`, and in the report's rows by their `row`.
  public let row: Int
  public let requirement: String
  public let layer: ValidationLayer
  public let result: QAResult
  public let atBase: Bool
  public let exitStatus: Int?
  public let milliseconds: Int
  public let evidence: [String]
  public let waitingOn: [String]
  /// The prepared at-base run whose result this row took instead of running; absent otherwise.
  public let reusedFrom: String?

  public init(
    plan: String, row: Int, requirement: String, layer: ValidationLayer, result: QAResult,
    atBase: Bool, exitStatus: Int?, milliseconds: Int, evidence: [String], waitingOn: [String],
    reusedFrom: String? = nil
  ) {
    self.plan = plan
    self.row = row
    self.requirement = requirement
    self.layer = layer
    self.result = result
    self.atBase = atBase
    self.exitStatus = exitStatus
    self.milliseconds = milliseconds
    self.evidence = evidence
    self.waitingOn = waitingOn
    self.reusedFrom = reusedFrom
  }

  public init(plan: String, row: QARow, atBase: Bool) {
    self.init(
      plan: plan, row: row.row, requirement: row.requirement, layer: row.layer,
      result: row.result, atBase: atBase, exitStatus: row.exitStatus,
      milliseconds: row.milliseconds, evidence: row.evidence, waitingOn: row.waitingOn,
      reusedFrom: row.reusedFrom)
  }

  private enum CodingKeys: String, CodingKey {
    case plan, row, requirement, layer, result, atBase, exitStatus, evidence, waitingOn,
      reusedFrom
    case milliseconds = "ms"
  }
}

/// `qa.flow`: 1 flow's steps, whichever source ran it. A batch flow's event joins its `qa.check`
/// by `plan` and `row` within the run; labels name selectors and commands, never output.
public struct QAFlowEvent: Sendable, Equatable, Codable {
  /// `nil` for a kept XCUITest flow, which no validation row runs.
  public let plan: String?
  /// 1-based position in `validation.json`'s `rows`; `nil` for a kept XCUITest flow.
  public let row: Int?
  public let requirement: String?
  public let atBase: Bool
  public let source: QAFlowSource
  public let steps: [QAFlowStep]
  /// Run-relative; absent until a final pass records one.
  public let video: String?
  /// Run-relative; absent until a final pass makes one.
  public let sheet: String?
  /// Why a final pass left no video; absent otherwise.
  public let videoUnverified: QARecordingGapReason?
  /// Why a final pass that made a video left no contact sheet; absent otherwise.
  public let sheetUnverified: QARecordingGapReason?
  /// The `[[flows]]` entry a kept XCUITest flow maps to; absent for a batch flow.
  public let flow: String?
  /// The kept flow's test, `<Class>/<method>()`; absent for a batch flow.
  public let test: String?

  public init(
    plan: String?, row: Int?, requirement: String?, atBase: Bool, record: QAFlowRecord
  ) {
    self.plan = plan
    self.row = row
    self.requirement = requirement
    self.atBase = atBase
    self.source = record.source
    self.steps = record.steps
    self.video = record.video
    self.sheet = record.sheet
    self.videoUnverified = record.videoUnverified
    self.sheetUnverified = record.sheetUnverified
    self.flow = record.flow
    self.test = record.test
  }

  public var record: QAFlowRecord {
    QAFlowRecord(
      source: source, steps: steps, video: video, sheet: sheet, videoUnverified: videoUnverified,
      sheetUnverified: sheetUnverified, flow: flow, test: test)
  }
}

/// `qa.repair`: `qa adopt --repair` took a requirement's rewritten checks into plan state, under
/// the prepared run that proved them red at the merge base. Ids, row numbers and the commands of
/// the steps it changed only: the orchestrator's reason stays in plan state's `qa/repairs.json`.
public struct QARepairEvent: Sendable, Equatable, Codable {
  public let plan: String
  public let requirement: String
  /// 1-based positions in `validation.json`'s `rows` whose checks it replaced.
  public let rows: [Int]
  public let buildRun: String
  public let cause: QAFlowRepair.Cause
  /// The `qa run`s that read the row red before the repair.
  public let redRuns: [String]
  /// The step those runs failed at, and its command.
  public let failingStep: Int?
  public let failingCommand: String?
  /// The commands of the steps the repair took out of the flow and put in.
  public let removed: [String]
  public let added: [String]

  public init(
    plan: String, requirement: String, rows: [Int], buildRun: String, cause: QAFlowRepair.Cause,
    redRuns: [String], failingStep: Int?, failingCommand: String?, removed: [String],
    added: [String]
  ) {
    self.plan = plan
    self.requirement = requirement
    self.rows = rows
    self.buildRun = buildRun
    self.cause = cause
    self.redRuns = redRuns
    self.failingStep = failingStep
    self.failingCommand = failingCommand
    self.removed = removed
    self.added = added
  }

  public init(plan: String, record: QAFlowRepairRecord) {
    self.init(
      plan: plan, requirement: record.requirement, rows: record.rows, buildRun: record.buildRun,
      cause: record.cause, redRuns: record.redRuns, failingStep: record.failingStep,
      failingCommand: record.failingCommand, removed: record.removed, added: record.added)
  }
}

/// 1 part of the setup before a `qa run`'s rows can run, and how long it took.
public struct QASetupStep: Sendable, Equatable, Codable {
  public enum Name: String, Sendable, Codable, CaseIterable {
    /// The tree the rows run in: a scratch tree or a pooled slot at the merge or the merge base.
    case tree
    /// Waiting for the device: a held one borrowed, or a new clone leased and booted.
    case device
    /// Building the app for the simulator.
    case build
    /// Installing the app on the device and opening it.
    case install
  }

  public let step: Name
  public let milliseconds: Int
  /// `true` when the step reused what an earlier run left: a warm slot, a held device, a build
  /// whose DerivedData existed. Absent when that isn't known.
  public let reused: Bool?

  public init(step: Name, milliseconds: Int, reused: Bool? = nil) {
    self.step = step
    self.milliseconds = milliseconds
    self.reused = reused
  }

  private enum CodingKeys: String, CodingKey {
    case step, reused
    case milliseconds = "ms"
  }
}

/// `qa.setup`: 1 setup step of 1 `qa run`, joined to its row's `qa.check` by `plan` and `row`
/// within the run; `row` is `nil` for the run's tree, which every row shares.
public struct QASetupEvent: Sendable, Equatable, Codable {
  public let plan: String
  public let row: Int?
  public let atBase: Bool
  public let step: QASetupStep.Name
  public let milliseconds: Int
  public let reused: Bool?

  public init(plan: String, row: Int?, atBase: Bool, setup: QASetupStep) {
    self.plan = plan
    self.row = row
    self.atBase = atBase
    self.step = setup.step
    self.milliseconds = setup.milliseconds
    self.reused = setup.reused
  }

  private enum CodingKeys: String, CodingKey {
    case plan, row, atBase, step, reused
    case milliseconds = "ms"
  }
}

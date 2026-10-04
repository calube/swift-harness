import Foundation
import SwiftGateDomain

/// The device a flow row is checked on: `sim up`, `sim verify` and `sim down` for 1 run, in the
/// worktree the row runs in.
public protocol QAFlowSimulating: Sendable {
  var agentDevice: any AgentDevice { get }
  func up(_ request: QAFlowSimulatorRequest) async -> Result<SimUpStarted, SimUpFailure>
  func verify(_ request: QAFlowSimulatorRequest) async -> Result<SimVerified, SimVerifyFailure>
  func down(_ request: QAFlowSimulatorRequest) async -> Result<SimDowned, SimDownFailure>
}

/// 1 flow row's simulator run.
public struct QAFlowSimulatorRequest: Sendable, Equatable {
  /// The tree the row runs in: the checkout, or a scratch tree at the merge base.
  public var worktree: URL
  public var runID: String
  /// The run's `sim/` folder, inside the `qa run`'s own run directory.
  public var simDirectory: URL
  /// `nil` launches the app with its live dependencies.
  public var scenario: String?

  public init(worktree: URL, runID: String, simDirectory: URL, scenario: String?) {
    self.worktree = worktree
    self.runID = runID
    self.simDirectory = simDirectory
    self.scenario = scenario
  }
}

/// What 1 batch showed: where it stopped, if anywhere, the flow's record, and the files it left.
public struct BatchFlowOutcome: Sendable, Equatable {
  public enum Stop: Sendable, Equatable {
    /// The flow failed at a step it wrote, or a capture after one: evidence about the app.
    case flow(BatchFlowPlan.Stop, message: String)
    /// The steps file isn't a flow `agent-device` runs.
    case flowFile(String)
    /// `agent-device` or the machine failed, so the batch says nothing about the app.
    case driver(String)
  }

  /// `nil` when every step passed.
  public var stop: Stop?
  public var record: QAFlowRecord
  /// Absolute paths of the files the batch left, beside the `sim/` steps.
  public var files: [URL]

  public init(stop: Stop?, record: QAFlowRecord, files: [URL]) {
    self.stop = stop
    self.record = record
    self.files = files
  }
}

/// Runs 1 prepared flow as 1 `agent-device batch` on a leased device and records each
/// assertion's tree and screenshot as a `sim/` step, as `sim snap` would.
public struct BatchFlowRunner: Sendable {
  /// The driven steps file, beside the flow's other evidence.
  public static let stepsFileName = "steps.json"
  /// The batch's `--json` output, as printed.
  public static let outputFileName = "batch.json"

  private let agentDevice: any AgentDevice

  public init(agentDevice: any AgentDevice) {
    self.agentDevice = agentDevice
  }

  /// - Parameters:
  ///   - stepsFile: the flow file as written.
  ///   - store: the run's `sim/` folder, whose `session.json` `sim up` wrote.
  ///   - flowDirectory: where the driven steps file and the batch output go.
  public func run(
    stepsFile: URL, on target: AgentDeviceTarget, store: SimRunStore, flowDirectory: URL
  ) async -> BatchFlowOutcome {
    BatchFlowOutcome(
      stop: .driver("not run"), record: QAFlowRecord(source: .batch, steps: []), files: [])
  }
}

/// 1 flow row as `qa run` checks it.
public struct QAFlowRow: Sendable, Equatable {
  public var row: Int
  public var requirement: String
  /// The flow file, absolute.
  public var stepsFile: URL
  /// The tree the row runs in.
  public var worktree: URL
  /// The row's folder in the run directory: its driven steps, batch output, record and `sim/`.
  public var directory: URL
  /// `directory` relative to the run directory, for the row's evidence paths.
  public var relativeDirectory: String
  /// The `sim up` run id, unique to this row within the `qa run`.
  public var runID: String
  /// At the merge base the requirement's state rows run whatever the batch showed, since each
  /// is expected to fail there and its reason is the point.
  public var atBase: Bool

  public init(
    row: Int, requirement: String, stepsFile: URL, worktree: URL, directory: URL,
    relativeDirectory: String, runID: String, atBase: Bool
  ) {
    self.row = row
    self.requirement = requirement
    self.stepsFile = stepsFile
    self.worktree = worktree
    self.directory = directory
    self.relativeDirectory = relativeDirectory
    self.runID = runID
    self.atBase = atBase
  }
}

/// Runs flow rows 1 at a time: lint, `sim up`, 1 batch, the requirement's state rows on the
/// device, `sim down`, then `sim verify`. `sim down` runs on every path once `sim up` was asked,
/// and `sim verify` runs after it, since crash reports reach the run's `sim/` folder only during
/// `sim down`.
public actor QAFlowRunner {
  /// The variables a state row gets while its flow's device is up.
  public static let udidVariable = "QA_SIM_UDID"
  public static let sessionVariable = "QA_SIM_SESSION"
  public static let bundleIDVariable = "QA_SIM_BUNDLE_ID"
  public static let simDirectoryVariable = "QA_SIM_DIR"

  private let simulator: any QAFlowSimulating
  private var flowRecords: [Int: QAFlowRecord] = [:]

  public init(simulator: any QAFlowSimulating) {
    self.simulator = simulator
  }

  /// The flow records of the rows that reached a batch, by row.
  public var records: [Int: QAFlowRecord] { flowRecords }

  /// - Parameter state: runs the requirement's state rows with the device's variables, while the
  ///   device is still up. It is called after a batch that passed, or at the merge base after any
  ///   batch, and never once the device is gone.
  public func run(
    _ row: QAFlowRow, lint: FlowLintReport,
    state: @Sendable ([String: String]) async -> Void
  ) async -> QACheckOutcome {
    QACheckOutcome(result: .unverified, message: QARunPlan.flowRunnerMissing)
  }
}

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
  /// What `sim up` opens the app with in place of the scenario's argument: the flow's first
  /// `open` step's `launchArgs`. `nil` opens it with the scenario's.
  public var launchArguments: [String]?
  /// Which controls `sim verify`'s accessibility rules judge.
  public var audit: SimAuditScope
  /// The `qa run`'s device the row borrows; `nil` brings a device up for the row alone.
  public var hold: QAFlowDeviceHold?

  public init(
    worktree: URL, runID: String, simDirectory: URL, scenario: String?,
    launchArguments: [String]? = nil, audit: SimAuditScope = .everyControl,
    hold: QAFlowDeviceHold? = nil
  ) {
    self.worktree = worktree
    self.runID = runID
    self.simDirectory = simDirectory
    self.scenario = scenario
    self.launchArguments = launchArguments
    self.audit = audit
    self.hold = hold
  }
}

/// The 1 device a `qa run` holds for all its flow rows: its hold's run id, and the folder its
/// holder logs to. A hold kept after the run is a build run's, which every `qa run` of that build
/// borrows in turn (``BuildRunDevice``).
public struct QAFlowDeviceHold: Sendable, Equatable {
  public var runID: String
  public var directory: URL
  /// `true` for a build run's hold: ``QAFlowRunner/finish()`` leaves it up, and its holder lasts
  /// until it is released or `timeoutMinutes` pass, not as long as this process.
  public var keptAfterRun: Bool
  /// How long a hold kept after the run lasts unreleased; `nil` for the config's session timeout.
  public var timeoutMinutes: Int?
  /// When a holder still waiting for a `sim` slot is stopped; `nil` outside a box.
  public var slotDeadline: QARunDeadline?

  public init(
    runID: String, directory: URL, keptAfterRun: Bool = false, timeoutMinutes: Int? = nil,
    slotDeadline: QARunDeadline? = nil
  ) {
    self.runID = runID
    self.directory = directory
    self.keptAfterRun = keptAfterRun
    self.timeoutMinutes = timeoutMinutes
    self.slotDeadline = slotDeadline
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
    /// The `record start` a final pass adds failed, so no step after the flow's opening `open` ran.
    case recordStart(AgentDeviceFailure)
  }

  /// `nil` when every step passed.
  public var stop: Stop?
  public var record: QAFlowRecord
  /// Absolute paths of the files the batch left, beside the `sim/` steps.
  public var files: [URL]
  /// When the batch's `record start` ended: when the video's first frame came, on the batch's
  /// clock. `nil` when the batch recorded nothing.
  public var videoStartMs: Int?

  public init(stop: Stop?, record: QAFlowRecord, files: [URL], videoStartMs: Int? = nil) {
    self.stop = stop
    self.record = record
    self.files = files
    self.videoStartMs = videoStartMs
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
  ///   - recordTo: set on a final pass: the batch holds a `record start` to this path, placed per
  ///     ``BatchFlowPlan/make(steps:screenshots:recordTo:)``.
  public func run(
    stepsFile: URL, on target: AgentDeviceTarget, store: SimRunStore, flowDirectory: URL,
    recordTo: String? = nil
  ) async -> BatchFlowOutcome {
    let empty = QAFlowRecord(source: .batch, steps: [])
    let steps: [FlowStep]
    do {
      steps = try FlowSteps.parse(try Data(contentsOf: stepsFile))
    } catch {
      return BatchFlowOutcome(
        stop: .flowFile("\(stepsFile.path) isn't a flow: \(error)"), record: empty, files: [])
    }
    var stagings: [SimStepStaging] = []
    do {
      for _ in 0..<BatchFlowPlan.assertionCount(steps) { stagings.append(try store.stage()) }
    } catch {
      return BatchFlowOutcome(stop: .driver(error.message), record: empty, files: [])
    }
    let plan = BatchFlowPlan.make(
      steps: steps, screenshots: stagings.map(\.screenshot.path), recordTo: recordTo)
    let driven = flowDirectory.appending(path: Self.stepsFileName)
    let output = flowDirectory.appending(path: Self.outputFileName)
    do {
      try QAFiles.write(plan.drivenJSON(), to: driven)
    } catch {
      stagings.forEach(store.discard)
      return BatchFlowOutcome(stop: .driver(error.description), record: empty, files: [])
    }

    let printed: Data?
    var stop: BatchFlowOutcome.Stop?
    var failedAt: Int?
    do {
      printed = try await agentDevice.batch(stepsFile: driven.path, on: target).json
    } catch {
      (printed, stop, failedAt) = Self.classify(error, plan: plan)
    }
    var files = [driven]
    if let printed {
      do {
        try QAFiles.write(printed, to: output)
        files.append(output)
      } catch {
        store.appendLog("qa run: \(error.description)")
      }
    }
    let results = printed.map(Self.results) ?? []
    commitEvidence(plan, stagings: stagings, results: results, store: store)
    let outcomes = results.map(\.outcome)
    return BatchFlowOutcome(
      stop: stop, record: plan.record(results: outcomes, failedAt: failedAt),
      files: files, videoStartMs: plan.videoStartMs(results: outcomes))
  }

  /// A failing step is evidence about the app; a refused steps file is the flow's fault; any
  /// other failure is the driver's or the machine's.
  private static func classify(_ error: AgentDeviceError, plan: BatchFlowPlan)
    -> (Data?, BatchFlowOutcome.Stop, Int?)
  {
    guard case .failed(_, let failure) = error else {
      return (error.output, .driver(error.message), nil)
    }
    // A busy recorder refuses the record start, whichever step the refusal names.
    if let recordIndex = plan.recordIndex, failure.reason == .appleSimulatorRecordingBusy {
      return (failure.output, .recordStart(failure), recordIndex)
    }
    if let step = failure.failedStep {
      if plan.stop(atDrivenIndex: step.index, command: step.command) == .recordStart {
        return (failure.output, .recordStart(failure), step.index)
      }
      return (
        failure.output,
        .flow(
          plan.stop(atDrivenIndex: step.index, command: step.command), message: failure.message),
        step.index
      )
    }
    switch failure.code {
    case .invalidArgs, .commandFailed:
      return (failure.output, .flowFile(error.message), nil)
    case .deviceInUse, .deviceNotFound, .sessionNotFound:
      return (failure.output, .driver(error.message), nil)
    }
  }

  /// 1 step of the printed output: its outcome and, for a `snapshot`, its `data`.
  private struct PrintedStep {
    var outcome: BatchStepOutcome
    var data: Any?
  }

  /// `data.results` of a passing batch, or `error.details.partialResults` of a failed one.
  private static func results(_ printed: Data) -> [PrintedStep] {
    guard let object = try? JSONSerialization.jsonObject(with: printed) as? [String: Any]
    else { return [] }
    let data = object["data"] as? [String: Any]
    let details = (object["error"] as? [String: Any])?["details"] as? [String: Any]
    let list = (data?["results"] ?? details?["partialResults"]) as? [[String: Any]] ?? []
    return list.compactMap { step in
      guard let index = step["step"] as? Int, let command = step["command"] as? String,
        let ok = step["ok"] as? Bool
      else { return nil }
      return PrintedStep(
        outcome: BatchStepOutcome(
          index: index, command: command, ok: ok, durationMs: step["durationMs"] as? Int ?? 0),
        data: step["data"])
    }
  }

  /// Commits 1 `sim/` step per assertion whose 3 captures all ran, with the first snapshot as
  /// its tree, and discards the screenshot staging of every other.
  private func commitEvidence(
    _ plan: BatchFlowPlan, stagings: [SimStepStaging], results: [PrintedStep], store: SimRunStore
  ) {
    let byIndex = Dictionary(
      results.map { ($0.outcome.index, $0) }, uniquingKeysWith: { first, _ in first })
    for (evidence, staging) in zip(plan.evidence, stagings) {
      guard let tree = byIndex[evidence.snapshot], tree.outcome.ok,
        let shot = byIndex[evidence.screenshot], shot.outcome.ok,
        let settle = byIndex[evidence.settle], settle.outcome.ok,
        let treeJSON = Self.envelope(tree.data), let settleJSON = Self.envelope(settle.data)
      else {
        store.discard(staging)
        continue
      }
      let elapsed =
        tree.outcome.durationMs + shot.outcome.durationMs + settle.outcome.durationMs
      do {
        _ = try store.commit(staging, treeJSON: treeJSON) { n in
          SimStep(
            n: n, label: evidence.label, assert: evidence.assert,
            screenshot: SimStep.screenshotPath(n: n), tree: SimStep.treePath(n: n),
            settled: SimStep.settled(before: treeJSON, after: settleJSON), elapsedMs: elapsed,
            target: evidence.target)
        }
      } catch {
        store.discard(staging)
        store.appendLog("qa run: \(error.message)")
      }
    }
  }

  /// A batch `snapshot` step's `data` in the envelope `snapshot --json` prints, which `sim verify`
  /// parses.
  private static func envelope(_ data: Any?) -> Data? {
    guard let data, JSONSerialization.isValidJSONObject(["data": data]) else { return nil }
    return try? JSONSerialization.data(
      withJSONObject: ["success": true, "data": data],
      options: [.sortedKeys, .withoutEscapingSlashes])
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
/// device, `sim down`, then `sim verify`. With a hold, every row borrows the 1 device it keeps
/// until ``finish()``, and its `sim up` resets the app before installing it. `sim down` runs on every path once `sim up` was asked,
/// and `sim verify` runs after it, since crash reports reach the run's `sim/` folder only during
/// `sim down`.
public actor QAFlowRunner {
  /// The variables a state row gets while its flow's device is up.
  public static let udidVariable = "QA_SIM_UDID"
  public static let sessionVariable = "QA_SIM_SESSION"
  public static let bundleIDVariable = "QA_SIM_BUNDLE_ID"
  public static let simDirectoryVariable = "QA_SIM_DIR"

  private let simulator: any QAFlowSimulating
  private let finalPass: QAFinalPass?
  private let recorder: FinalPassRecorder?
  private let hold: QAFlowDeviceHold?
  /// The tree whose rows have asked for the shared device, once 1 has.
  private var heldIn: URL?
  private var flowRecords: [Int: QAFlowRecord] = [:]
  private var setupSteps: [Int: [QASetupStep]] = [:]
  private var evidenceGaps: [QAEvidenceGap] = []

  /// - Parameters:
  ///   - finalPass: set for `qa run --final`, which records each batch and saves its logs.
  ///   - recorder: without `finalPass`, records each batch's video and contact sheet and saves
  ///     no logs; a recording it can't make leaves no gap, since only a final pass owes one, and
  ///     the row's message says why it has no video.
  ///   - hold: the device every row borrows in turn, held until ``finish()``; `nil` brings a
  ///     device up for each row.
  public init(
    simulator: any QAFlowSimulating, finalPass: QAFinalPass? = nil,
    recorder: FinalPassRecorder? = nil, hold: QAFlowDeviceHold? = nil
  ) {
    self.simulator = simulator
    self.finalPass = finalPass
    self.recorder = recorder
    self.hold = hold
  }

  /// Gives back the device the rows shared, in the tree they ran in. Returns what went wrong,
  /// if anything; a run with no row that asked for the device gives nothing back, and a build
  /// run's hold stays up for the next `qa run`.
  public func finish() async -> [String] {
    guard let hold, !hold.keptAfterRun, let worktree = heldIn else { return [] }
    heldIn = nil
    let request = QAFlowSimulatorRequest(
      worktree: worktree, runID: hold.runID, simDirectory: hold.directory, scenario: nil,
      hold: hold)
    switch await simulator.down(request) {
    case .success: return []
    case .failure(let failure):
      return ["the flow rows' shared device: sim down \(failure.rule.rawValue): \(failure.message)"]
    }
  }

  /// The setup steps of each row whose `sim up` got the app up, by row.
  public var setup: [Int: [QASetupStep]] { setupSteps }

  /// The flow records of the rows that reached a batch, by row.
  public var records: [Int: QAFlowRecord] { flowRecords }

  /// The final-pass evidence each flow row didn't leave, in row order.
  public var gaps: [QAEvidenceGap] { evidenceGaps }

  /// - Parameter state: runs the requirement's state rows with the device's variables, while the
  ///   device is still up. It is called after a batch that passed, or at the merge base after any
  ///   batch, and never once the device is gone.
  public func run(
    _ row: QAFlowRow, lint: FlowLintReport,
    state: @Sendable ([String: String]) async -> Void
  ) async -> QACheckOutcome {
    let start = ContinuousClock.now
    var evidence: [String] = []
    func outcome(_ result: QAResult, _ message: String) -> QACheckOutcome {
      QACheckOutcome(
        result: result, message: message, milliseconds: Self.milliseconds(since: start),
        evidence: evidence)
    }
    if lint.verdict != .green {
      let file = row.directory.appending(path: "lint.txt")
      let lines =
        ["qa lint: \(lint.verdict.rawValue) \(lint.message)"]
        + lint.findings.map { "  \($0.ruleID): \($0.message)" }
      let text = lines.joined(separator: "\n") + "\n"
      if (try? QAFiles.write(Data(text.utf8), to: file)) != nil {
        evidence.append("\(row.relativeDirectory)/lint.txt")
      }
      let rules = Set(lint.findings.filter { $0.severity.failsGate }.map(\.ruleID)).sorted()
      return lint.verdict == .red
        ? outcome(.red, "qa lint: \(rules.joined(separator: ", ")): \(lint.message)")
        : outcome(.unverified, "not run: qa lint couldn't run: \(lint.message)")
    }

    let simDirectory = row.directory.appending(path: "sim", directoryHint: .isDirectory)
    let steps = (try? Data(contentsOf: row.stepsFile)).flatMap { try? FlowSteps.parse($0) }
    let request = QAFlowSimulatorRequest(
      worktree: row.worktree, runID: row.runID, simDirectory: simDirectory, scenario: nil,
      launchArguments: steps.map(FlowSteps.launchArguments),
      audit: Self.audit(row, steps: steps ?? []), hold: hold)
    if hold != nil { heldIn = row.worktree }
    let started: SimUpStarted
    switch await simulator.up(request) {
    case .failure(let failure):
      let notes = await down(request)
      return outcome(
        .unverified,
        "not run: sim up \(failure.rule.rawValue): \(failure.message)" + Self.suffix(notes))
    case .success(let up):
      started = up
      setupSteps[row.row] = up.setup
    }

    let target = AgentDeviceTarget(udid: started.udid, session: started.session)
    let store = SimRunStore(simDirectory: simDirectory)
    let runner = BatchFlowRunner(agentDevice: simulator.agentDevice)
    let batch: BatchFlowOutcome
    var record: QAFlowRecord
    var finalFiles: [String] = []
    var videoNote: String?
    if let finalPass {
      let recorded = await self.recorded(
        row, finalPass: finalPass, target: target, store: store, runner: runner)
      batch = recorded.outcome
      record = recorded.record
      finalFiles = recorded.files
    } else if let recorder {
      let stepsFile = row.stepsFile
      let directory = row.directory
      let (outcome, recording) = await recorder.record(
        on: target, directory: directory, relativeDirectory: row.relativeDirectory
      ) { recordTo in
        await runner.run(
          stepsFile: stepsFile, on: target, store: store, flowDirectory: directory,
          recordTo: recordTo)
      }
      batch = outcome
      var made = recording
      if made.video == nil, let gap = made.videoGap { videoNote = "no video: \(gap.detail)" }
      made.videoGap = nil
      made.sheetGap = nil
      record = outcome.record.recorded(made)
      finalFiles = Self.paths(made)
    } else {
      batch = await runner.run(
        stepsFile: row.stepsFile, on: target, store: store, flowDirectory: row.directory)
      record = batch.record
    }
    evidence += batch.files.map { "\(row.relativeDirectory)/\($0.lastPathComponent)" }
    if !record.steps.isEmpty {
      flowRecords[row.row] = record
      let recordFile = row.directory.appending(path: QAFlowRecord.fileName)
      let written = (try? record.encoded()).map { data in
        (try? QAFiles.write(data, to: recordFile)) != nil
      }
      if written == true {
        evidence.append("\(row.relativeDirectory)/\(QAFlowRecord.fileName)")
      }
    }
    evidence += finalFiles
    // A batch that stopped before its first capture snapped no step, so it has no step log.
    if FileManager.default.fileExists(
      atPath: simDirectory.appending(path: SimStep.logFileName).path)
    {
      evidence.append("\(row.relativeDirectory)/sim/\(SimStep.logFileName)")
    }

    if batch.stop == nil || row.atBase {
      await state(Self.environment(started, simDirectory: simDirectory))
    }
    let notes = await down(request)
    let verdict = await judge(
      request, relativeDirectory: row.relativeDirectory, evidence: &evidence)

    let (result, message): (QAResult, String)
    switch batch.stop {
    case .flow(.step(let n, let command), let why)?:
      let judged = verdict.result == .red ? "; \(verdict.message)" : ""
      (result, message) = (.red, "step \(n) `\(command)` failed: \(why)\(judged)")
    case .flow(.evidence(let after, let command), let why)?:
      (result, message) = (
        .unverified, "not judged: the \(command) after step \(after) failed: \(why)"
      )
    case .flowFile(let why)?:
      (result, message) = (.red, "the flow file doesn't run: \(why)")
    case .driver(let why)?:
      (result, message) = (.unverified, "not run: \(why)")
    case .recordStart(let failure)?:
      (result, message) = (.unverified, "not run: record start failed: \(failure.message)")
    case .flow(.recordStart, let why)?:
      (result, message) = (.unverified, "not run: record start failed: \(why)")
    case nil:
      (result, message) = (verdict.result, verdict.message)
    }
    return outcome(result, message + Self.suffix((videoNote.map { [$0] } ?? []) + notes))
  }

  /// The row's batch inside a recording and its logs: the outcome, the record with its video and
  /// sheet, and the files the final pass left. Each gap is kept for the report.
  private func recorded(
    _ row: QAFlowRow, finalPass: QAFinalPass, target: AgentDeviceTarget, store: SimRunStore,
    runner: BatchFlowRunner
  ) async -> (outcome: BatchFlowOutcome, record: QAFlowRecord, files: [String]) {
    let name = row.directory.lastPathComponent.replacing(/\.flow$/, with: "")
    let logs = row.directory.deletingLastPathComponent()
      .appending(path: "\(EvidenceCollector.directory)/\(name)", directoryHint: .isDirectory)
    let relativeLogs =
      (row.relativeDirectory.split(separator: "/").dropLast() + [
        Substring(EvidenceCollector.directory), Substring(name),
      ]).joined(separator: "/")
    let stepsFile = row.stepsFile
    let directory = row.directory
    let relativeDirectory = row.relativeDirectory
    @Sendable func record() async -> (outcome: BatchFlowOutcome, recording: QAFlowRecording) {
      await finalPass.recorder.record(
        on: target, directory: directory, relativeDirectory: relativeDirectory
      ) { recordTo in
        await runner.run(
          stepsFile: stepsFile, on: target, store: store, flowDirectory: directory,
          recordTo: recordTo)
      }
    }

    let session: SimSession
    do {
      session = try store.session()
    } catch {
      let (outcome, recording) = await record()
      let reason =
        "the run's \(SimSession.fileName) doesn't read, so no log names the app: \(error)"
      evidenceGaps +=
        recording.gaps(row: row.row)
        + EvidenceCollector.logKinds.map { QAEvidenceGap(row: row.row, kind: $0, reason: reason) }
      return (outcome, outcome.record.recorded(recording), Self.paths(recording))
    }
    let device = QAEvidenceDevice(
      target: target, bundleID: session.bundleID, since: session.startedAt)
    let ((outcome, recording), collection) = await finalPass.evidence.collect(
      on: device, directory: logs, relativeDirectory: relativeLogs, record)
    evidenceGaps +=
      recording.gaps(row: row.row)
      + EvidenceCollector.logKinds.compactMap { kind in
        collection.gaps[kind].map { QAEvidenceGap(row: row.row, kind: kind, reason: $0) }
      }
    return (
      outcome, outcome.record.recorded(recording), Self.paths(recording) + collection.files
    )
  }

  private static func paths(_ recording: QAFlowRecording) -> [String] {
    [recording.video, recording.sheet].compactMap { $0 }
  }

  private static func environment(_ started: SimUpStarted, simDirectory: URL) -> [String: String] {
    var environment = [
      udidVariable: started.udid, sessionVariable: started.session,
      simDirectoryVariable: simDirectory.path,
    ]
    if let session = try? SimRunStore(simDirectory: simDirectory).session() {
      environment[bundleIDVariable] = session.bundleID
    }
    return environment
  }

  /// The controls the row's `sim verify` audits: every one in an owned repository, and in a
  /// brownfield clone those the flow file's steps select. A flow file that doesn't parse selects
  /// none; the batch reports it.
  static func audit(_ row: QAFlowRow, steps: [FlowStep]) -> SimAuditScope {
    .scope(profile: StateRootResolver.profile(worktree: row.worktree), flowSteps: steps)
  }

  /// `sim verify` over the row's `sim/` folder: only `GREEN` passes.
  private func judge(
    _ request: QAFlowSimulatorRequest, relativeDirectory: String, evidence: inout [String]
  ) async -> (result: QAResult, message: String) {
    switch await simulator.verify(request) {
    case .failure(let failure):
      return (
        failure.verdict == .red ? .red : .unverified,
        "sim verify \(failure.rule.rawValue): \(failure.message)"
      )
    case .success(let verified):
      evidence.append("\(relativeDirectory)/sim/\(SimVerifyReport.fileName)")
      let report = verified.report
      let nits = report.notes.map { "; nit \($0.rule): \($0.message)" }.joined()
      switch report.verdict {
      case .green:
        let steps = report.stepCount.map { $0 == 1 ? "1 step" : "\($0) steps" } ?? "its steps"
        return (.pass, "batch passed; sim verify GREEN over \(steps)" + nits)
      case .red:
        let found = report.findings.map { "\($0.rule.rawValue): \($0.message)" }
        return (.red, "sim verify RED: " + found.joined(separator: "; ") + nits)
      case .blocked:
        return (.unverified, "not judged: sim verify BLOCKED: \(report.blocked ?? "no reason")")
      }
    }
  }

  private func down(_ request: QAFlowSimulatorRequest) async -> [String] {
    switch await simulator.down(request) {
    case .success(let downed): return downed.notes.map { "sim down: \($0)" }
    case .failure(let failure):
      return ["sim down \(failure.rule.rawValue): \(failure.message)"]
    }
  }

  private static func suffix(_ notes: [String]) -> String {
    notes.isEmpty ? "" : "; " + notes.joined(separator: "; ")
  }

  private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
    let (seconds, attoseconds) = (ContinuousClock.now - start).components
    return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
  }
}

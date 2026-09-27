import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

struct BuildRecordGateReport: Sendable, Equatable, Encodable {
  let command: String
  let plan: String
  let buildRunId: String
  /// `merge` or `final`.
  let stage: String
  let task: String?
  let tier: CheckTier
  let verdict: Verdict
  let runId: String
}

/// Records a gate the orchestrator ran on `main` in the build run's event log, so the ledger page
/// can show it. The tier and verdict come from the gate run's own history line, never the caller.
enum BuildRecordGateRun {
  static func run(
    slug: String, stage: BuildEvent.Gate.Stage, runID: String, session: String?, root: URL,
    git: any Git, clock: any BuildClock
  ) async -> BuildLoopResult<BuildRecordGateReport> {
    let command = "build record-gate"
    if let refusal: BuildLoopResult<BuildRecordGateReport> = await BuildLoop.authorize(
      command, slug: slug, session: session, git: git)
    {
      return refusal
    }
    let runs = RunStore(worktreeRoot: root)
    let record: RunHistoryRecord
    do throws(RunStoreError) {
      guard let found = try runs.readHistory().records.last(where: { $0.runID == runID }) else {
        return .blocked(command, slug, "run \(runID) isn't in \(runs.historyFile.path)")
      }
      record = found
    } catch {
      return .blocked(command, slug, "reading \(runs.historyFile.path): \(error)")
    }
    guard let tier = TaskReturnEvidence.GateRun.tier(ofCommand: record.command) else {
      return .blocked(
        command, slug,
        "run \(runID) was `\(record.command ?? "an unnamed command")`, not a `check --tier` run")
    }
    let gate = BuildEvent.Gate(
      stage: stage, tier: tier, verdict: record.verdict, runID: runID, at: clock.now())
    let store: BuildRunStore
    do throws(BuildRunStoreError) {
      guard let latest = try await BuildRunStore.latest(plan: slug, git: git) else {
        return .blocked(command, slug, "plan `\(slug)` has no build run to record the gate in")
      }
      store = latest
      try await store.append(.gate(gate))
    } catch {
      return .blocked(command, slug, "recording the gate: \(error)")
    }
    let task: String? =
      switch stage {
      case .merge(let task): task
      case .final: nil
      }
    let label = task.map { "merge gate for `\($0)`" } ?? "final gate"
    return BuildLoopResult(
      command: command, plan: slug, verdict: .green,
      report: BuildRecordGateReport(
        command: command, plan: slug, buildRunId: store.runID,
        stage: task == nil ? "final" : "merge", task: task, tier: tier, verdict: record.verdict,
        runId: runID),
      holder: nil,
      message: "recorded the \(label): \(tier.rawValue) \(record.verdict.rawValue), run \(runID)")
  }

  static func render(_ result: BuildLoopResult<BuildRecordGateReport>, format: OutputFormat)
    -> String
  {
    BuildLoop.render(result, format: format) { _ in "build record-gate: \(result.message)" }
  }
}

struct BuildRecordGateCommand: AsyncParsableCommand {
  enum Kind: String, ExpressibleByArgument, CaseIterable {
    case merge
    case final
  }

  static let configuration = CommandConfiguration(
    commandName: "record-gate",
    abstract: "Record a merge gate or the final gate that ran on main in the build run's log.",
    discussion:
      "Reads the gate run's tier and verdict from this checkout's run history and appends them "
      + "to the plan's newest build run, where the ledger page reads them. Exits 0, 1 when "
      + "--session doesn't hold the plan's lock, and 2 when the run isn't a recorded `check` run "
      + "or the build run can't be read.")

  @Argument(help: "The plan's slug.")
  var plan: String

  @Option(help: "merge: the merge gate after --task merged. final: the final gate.")
  var kind: Kind

  @Option(help: "The task whose merge the gate checked; merge gates only.")
  var task: String?

  @Option(name: .customLong("run-id"), help: "The gate run's id, as `check` printed it.")
  var runID: String

  @Option(help: "The session id holding the plan's lock (from the SessionStart context).")
  var session: String?

  @OptionGroup var output: OutputOptions

  func validate() throws {
    switch (kind, task) {
    case (.merge, nil): throw ValidationError("--kind merge needs --task <task>")
    case (.final, .some): throw ValidationError("--kind final takes no --task")
    default: break
    }
  }

  func run() async throws {
    let stage: BuildEvent.Gate.Stage = task.map { .merge(task: $0) } ?? .final
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let result = await BuildRecordGateRun.run(
      slug: plan, stage: stage, runID: runID, session: session, root: root, git: BuildLoop.git(),
      clock: LiveBuildClock())
    Console.write(BuildRecordGateRun.render(result, format: output.format))
    try BuildLoop.exit(result)
  }
}

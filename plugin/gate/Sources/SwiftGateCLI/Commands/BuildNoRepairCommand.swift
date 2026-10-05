import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

struct BuildNoRepairReport: Sendable, Equatable, Encodable {
  let command: String
  let plan: String
  let task: String
  let requirement: String
  /// `contract-gap` or `app-at-fault`.
  let cause: BuildEvent.RowsUnverified.Cause
  let contractName: String?
  let qaRun: String
  let action: NoRepairDecision.Action
  let rows: [Int]
  let why: String
  /// The `build halt` answer the decision takes; `nil` for an amendment, which halts nothing.
  let answer: String?
  /// Whether this call wrote the rows left unverified to the build run's log.
  let recorded: Bool
}

/// Decides a task whose flow row's repair worker returned `no repair:`, by
/// ``NoRepairDecision``. A `merge-unverified` decision is recorded in the build run, where `build
/// merge` and the final `qa run` read the rows it leaves.
enum BuildNoRepairRun {
  static let command = "build no-repair"

  static func run(
    slug: String, task: String, reply: String, qaRun: String, fixReturn: String,
    session: String?, root: URL, git: any Git, clock: any BuildClock
  ) async -> BuildLoopResult<BuildNoRepairReport> {
    if let refusal: BuildLoopResult<BuildNoRepairReport> = await BuildLoop.authorize(
      command, slug: slug, session: session, git: git)
    {
      return refusal
    }
    guard let text = try? String(contentsOfFile: reply, encoding: .utf8) else {
      return .blocked(command, slug, "\(reply) doesn't read")
    }
    guard let noRepair = FlowNoRepair.parse(text) else {
      return .blocked(
        command, slug,
        "\(reply) holds no `no repair: <requirement>: <why>` line: a `repaired:` return goes to "
          + "`qa adopt --repair`")
    }
    let returned: TaskReturn
    do {
      returned = try TaskReturnJSON.decode(try Data(contentsOf: URL(filePath: fixReturn)))
    } catch {
      return .blocked(command, slug, "\(fixReturn) isn't a task return: \(error)")
    }
    guard returned.task == task else {
      return .blocked(
        command, slug, "\(fixReturn) is task `\(returned.task)`'s return, not `\(task)`'s")
    }
    let reports = QARunHistory.beforeMergeReports(worktree: root, plan: slug)
    guard let report = reports.first(where: { $0.runID == qaRun }) else {
      return .blocked(
        command, slug,
        "no `qa run --before-merge` report of plan `\(slug)` with run id \(qaRun) under the "
          + "runs of any checkout of this clone")
    }
    let store: BuildRunStore
    let record: BuildRunRecord
    do throws(BuildRunStoreError) {
      guard let latest = try await BuildRunStore.latest(plan: slug, git: git) else {
        return .blocked(command, slug, "plan `\(slug)` has no build run")
      }
      store = latest
      record = try store.record()
    } catch {
      return .blocked(command, slug, "reading the build run: \(error)")
    }
    let now = clock.now()
    let decision = NoRepairDecision.decide(
      noRepair, run: report.rows,
      runSeconds: report.rows.reduce(0) { $0 + $1.milliseconds } / 1000,
      fixGate: returned.gate?.verdict, now: now, noNewStartsAt: record.noNewStartsAt,
      cutoffAt: record.cutoffAt)
    let (cause, name): (BuildEvent.RowsUnverified.Cause, String?) =
      switch noRepair.cause {
      case .contractGap(let name): (.contractGap, name)
      case .appAtFault, .appDefect: (.appAtFault, nil)
      }
    var recorded = false
    if decision.action == .mergeUnverified {
      let left = BuildEvent.RowsUnverified(
        task: task, requirement: noRepair.requirement, rows: decision.rows, qaRun: qaRun,
        cause: cause, contractName: name, at: now)
      do throws(BuildRunStoreError) {
        recorded = try await store.append(.rowsUnverified(left)) { held in
          guard case .rowsUnverified(let old) = held else { return false }
          return old.task == task && old.qaRun == qaRun && old.rows == decision.rows
        }
      } catch {
        return .blocked(command, slug, "recording the rows left unverified: \(error)")
      }
    }
    let answer: String? =
      switch decision.action {
      case .amendContract: nil
      case .mergeUnverified: BuildResumeAnswer.merge.rawValue
      case .continue: BuildResumeAnswer.continue.rawValue
      case .fixAgain: BuildResumeAnswer.retry.rawValue
      }
    return BuildLoopResult(
      command: command, plan: slug, verdict: .green,
      report: BuildNoRepairReport(
        command: command, plan: slug, task: task, requirement: noRepair.requirement,
        cause: cause, contractName: name, qaRun: qaRun, action: decision.action,
        rows: decision.rows, why: decision.why, answer: answer, recorded: recorded),
      holder: nil, message: "\(decision.action.rawValue): \(decision.why)")
  }

  static func render(_ result: BuildLoopResult<BuildNoRepairReport>, format: OutputFormat)
    -> String
  {
    BuildLoop.render(result, format: format) { _ in "build no-repair: \(result.message)" }
  }
}

struct BuildNoRepairCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "no-repair",
    abstract: "Decide a task whose flow row's repair worker returned `no repair:`.",
    discussion:
      "Reads the worker's reply, the fixer's return and the before-merge `qa run` the row was "
      + "red in, and prints `amend-contract` (a contract gap with time for another round before "
      + "no new starts), `merge-unverified` (the fixer's gate GREEN and every other row passed: "
      + "recorded, so `build merge --fix` takes the run red on those rows alone and the final "
      + "`qa run` reports them unverified) or `continue` (the task stays blocked). It never "
      + "answers stop the build. Exits 0, 1 when --session doesn't hold the plan's lock, and 2 "
      + "when an input doesn't read.")

  @Argument(help: "The plan's slug.")
  var plan: String

  @Argument(help: "The task whose row the repair worker answered.")
  var task: String

  @Option(help: "A file holding the repair worker's reply, with its `no repair:` line.")
  var reply: String

  @Option(name: .customLong("qa-run"), help: "The before-merge `qa run` id the row was red in.")
  var qaRun: String

  @Option(name: .customLong("fix-return"), help: "The fixer's return file, as checked.")
  var fixReturn: String

  @Option(help: "The session id holding the plan's lock (from the SessionStart context).")
  var session: String?

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let result = await BuildNoRepairRun.run(
      slug: plan, task: task, reply: reply, qaRun: qaRun, fixReturn: fixReturn,
      session: session, root: root, git: BuildLoop.git(), clock: LiveBuildClock())
    Console.write(BuildNoRepairRun.render(result, format: output.format))
    try BuildLoop.exit(result)
  }
}

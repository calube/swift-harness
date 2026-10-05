import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// What `build cutoff` decided for a brownfield run's not-done tasks.
struct BuildCutoffReport: Sendable, Equatable, Encodable {
  let command: String
  let plan: String
  let runId: String
  let at: Date
  let endsAt: Date
  /// Tasks whose merge gate still fits: merge them, in this order, then run `final`.
  let finish: [String]
  /// The tasks in `finish` whose merge and GREEN merge gate are already recorded: only the steps
  /// after a merge gate are left for them.
  let landed: [String]
  /// Tasks set `abandoned`, each with why it didn't fit the box.
  let abandoned: [CutoffDecision]
  /// Tasks that never started and stay as they are.
  let notStarted: [String]
  /// Where the decisions were written for the report.
  let path: String
  /// Gates that were still running in an abandoned task's worktree, each as `<tier> in <path>`.
  let stoppedGates: [String]
  /// Scratch trees left by gates that ended without removing them.
  let prunedScratchTrees: [String]
  /// Telemetry lines that failed; the decisions stand without them.
  let notes: [String]
}

/// What `build cutoff` reads of the run's past to price landing each task.
struct CutoffHistory: Sendable {
  /// Each recorded gate run's duration in milliseconds, by run id.
  var gateMilliseconds: [String: Int] = [:]
  /// The plan's `qa run --before-merge` reports.
  var beforeMergeReports: [QAReport] = []
  /// What `final` would still run on the checkout's tree, which prices it before any `final` is
  /// recorded; `nil` when that can't be read.
  var finalReuse: FinalGateReuse? = nil
}

/// `build cutoff`: the brownfield run's answer to the time box's cutoff, decided by
/// ``CutoffRule`` with no one asked.
enum BuildCutoffRun {
  static let command = "build cutoff"

  /// Acts at the cutoff, or once starts have stopped with nothing running, when the only tasks
  /// left are ones that never started. Owned runs, which have no box, are refused: their build
  /// halts and asks.
  /// - Parameters:
  ///   - leftovers: stops the gates of the tasks it abandons and prunes scratch trees; `nil`
  ///     leaves both alone.
  ///   - finalSeconds: how long the clone's `final` gate takes, which grows the final reserve and
  ///     brings the cutoff earlier.
  ///   - history: the gates and before-merge qa runs that price each task's landing.
  static func run(
    slug: String, session: String?, git: any Git, clock: any BuildClock,
    telemetry: BuildCutoffTelemetry?, leftovers: (any RunLeftovers)? = nil,
    finalSeconds: Int? = nil, history: CutoffHistory = CutoffHistory()
  ) async -> BuildLoopResult<BuildCutoffReport> {
    if let refusal: BuildLoopResult<BuildCutoffReport> = await BuildLoop.authorize(
      command, slug: slug, session: session, git: git)
    {
      return refusal
    }
    do throws(BuildLoopError) {
      let plan: PlanStateLayout.Plan
      do {
        plan = try await BuildLoop.planLayout(slug, git: git).plan(slug)
      } catch {
        return .blocked(command, slug, "invalid plan name `\(slug)`: \(error)")
      }
      let store: BuildRunStore
      let record: BuildRunRecord
      let log: BuildEventLog
      do throws(BuildRunStoreError) {
        guard let latest = try await BuildRunStore.latest(plan: slug, git: git) else {
          return .blocked(command, slug, "plan `\(slug)` has no build run to cut off")
        }
        store = latest
        record = try store.record()
        log = try store.events()
      } catch {
        return .blocked(command, slug, "reading plan `\(slug)`'s build run: \(error)")
      }
      guard let recorded = record.timeBox else {
        return .blocked(
          command, slug,
          "build run \(record.runID) has no time box: an owned build halts and asks at its "
            + "cutoff, and only a `swiftgate run` decides its own")
      }
      let box = RunTimeBox(
        startedAt: recorded.startedAt, limits: recorded.limits.holding(finalSeconds: finalSeconds))
      let ledger = try BuildLoop.ledger(plan)
      let now = clock.now()
      let running = ledger.tasks.filter { $0.status == .inProgress }
      let phase = box.phase(at: now)
      guard phase == .cutoff || (phase == .noNewStarts && running.isEmpty) else {
        let wait = max(0, Int(box.deadlines.cutoffAt.timeIntervalSince(now).rounded(.up)))
        return .refused(
          command, slug, .red,
          "the cutoff comes in \(wait) s, at \(box.deadlines.cutoffAt.formatted(.iso8601)); "
            + "running tasks keep going until then")
      }
      var tasks: [CutoffTask] = []
      for task in ledger.tasks {
        switch task.status {
        case .inProgress:
          // The ledger reads `done` only after a merge's post-merge steps, so the run's events
          // say whether its merge and merge gate already happened.
          if let stage = log.mergeStage(task: task.id) {
            tasks.append(CutoffTask(id: task.id, stage: stage))
          } else if readyToMerge(task.id, run: store.layout.directory) {
            tasks.append(
              CutoffTask(
                id: task.id, stage: .gating,
                beforeMergeQASeconds: await beforeMergeQASeconds(
                  task.id, slug: slug, plan: plan, ledger: ledger, log: log,
                  reports: history.beforeMergeReports, git: git)))
          } else {
            tasks.append(CutoffTask(id: task.id, stage: .working))
          }
        case .pending, .blocked: tasks.append(CutoffTask(id: task.id, stage: .notStarted))
        case .done, .abandoned, .needsReplan: continue
        }
      }
      let decisions = CutoffRule.decide(
        tasks: tasks, timeBox: box, now: now,
        costs: CutoffCosts.measured(log: log, milliseconds: history.gateMilliseconds))
      let path = store.layout.directory + "/" + CutoffRecord.fileName
      do {
        try CutoffRecord(at: now, timeBox: box, decisions: decisions).encoded()
          .write(to: URL(filePath: path), options: .atomic)
      } catch {
        return .blocked(command, slug, "writing \(path): \(error)")
      }
      let abandoned = decisions.filter { $0.action == .abandon }
      for decision in abandoned {
        let set = await LedgerSetRun.run(
          plan: slug, task: decision.task, status: TaskStatus.abandoned.rawValue,
          session: session, now: now, git: git)
        guard set.verdict == .green else {
          return .blocked(
            command, slug,
            "abandoning `\(decision.task)`: \(set.message); the decisions are in \(path)")
        }
      }
      // A gate still running in an abandoned task's worktree would only hold the machine, and
      // its scratch tree would outlive it.
      let worktrees = ledger.tasks.filter { task in abandoned.contains { $0.task == task.id } }
        .map(\.worktree)
      let stopped = await leftovers?.stopGates(in: worktrees) ?? []
      let sweep = await leftovers?.pruneScratchTrees() ?? ScratchWorktreeSweep()
      let notes =
        recordHalts(decisions, run: record.runID, telemetry: telemetry)
        + sweep.failures.map { "a scratch tree wasn't pruned: \($0)" }
      return BuildLoopResult(
        command: command, plan: slug, verdict: .green,
        report: BuildCutoffReport(
          command: command, plan: slug, runId: record.runID, at: now,
          endsAt: box.deadlines.endsAt,
          finish: decisions.filter { $0.action == .finishMerge }.map(\.task),
          landed: tasks.filter { $0.stage == .landed }.map(\.id),
          abandoned: abandoned,
          notStarted: decisions.filter { $0.action == .notStarted }.map(\.task), path: path,
          stoppedGates: stopped.map { "\($0.tier) in \($0.toplevel)" },
          prunedScratchTrees: sweep.removed, notes: notes),
        holder: nil,
        message: "cut off build run \(record.runID): \(abandoned.count) task(s) abandoned")
    } catch {
      return .blocked(command, slug, error.message)
    }
  }

  /// What `task`'s `qa run --before-merge` still costs: 0 when its merge makes no row ready, or
  /// when a GREEN or conflicted run covers the branch it merges (its fixer's, when its newest
  /// checked return is the fixer's) at its tip on the plan branch's head. Otherwise the newest
  /// such run's rows, whatever tip it ran, in whole seconds rounded up, or 0 with none recorded.
  private static func beforeMergeQASeconds(
    _ task: String, slug: String, plan: PlanStateLayout.Plan, ledger: Ledger, log: BuildEventLog,
    reports: [QAReport], git: any Git
  ) async -> Int {
    guard
      let data = FileManager.default.contents(
        atPath: plan.directory + "/" + ValidationTable.fileName),
      let table = try? ValidationTableJSON.decode(data)
    else { return 0 }
    let fix =
      log.events.last { event in
        if case .returnCheck(let check) = event { return check.task == task }
        return false
      }.map { event in
        if case .returnCheck(let check) = event { return check.fix }
        return false
      } ?? false
    var branch = "\(slug)/\(fix ? "fix-\(task)" : task)"
    var tip: String?
    var base: String?
    if let common = try? await git.commonDirectory(),
      let names = try? TaskWorktree(
        commonDirectory: common, plan: slug, task: fix ? "fix-\(task)" : task,
        profile: .brownfield)
    {
      branch = names.branch
      tip = try? await git.revision("refs/heads/\(names.branch)")
      base = try? await git.revision("refs/heads/\(names.baseBranch)")
    }
    let own = reports.filter { $0.after == task }
    let merged = LedgerProgress(tasks: ledger.tasks.map { .init(id: $0.id, status: $0.status) })
      .merged(per: log)
    switch QAMergeReadiness.of(
      table: table, merged: merged, plan: slug, task: task, reports: own, branch: branch,
      tip: tip ?? "", base: base ?? "")
    {
    case .notNeeded, .checked, .conflicts:
      return 0
    case .unchecked, .red:
      guard let newest = own.max(by: { ($0.runID ?? "") < ($1.runID ?? "") }) else { return 0 }
      return (newest.rows.reduce(0) { $0 + $1.milliseconds } + 999) / 1000
    }
  }

  /// Whether the run holds a checked `ready-to-merge` return for `task`.
  private static func readyToMerge(_ task: String, run directory: String) -> Bool {
    guard
      let data = try? Data(contentsOf: URL(filePath: directory + "/returns/\(task).json")),
      let taskReturn = try? TaskReturnJSON.decode(data)
    else { return false }
    return taskReturn.outcome == .readyToMerge
  }

  /// The cutoff as answered halts: 1 for the run, then 1 per running task, each resumed at once
  /// with what the rule chose, so the viewer and the halt summary show it and none stays open.
  /// Returns a line per event that failed; the decisions stand without them.
  private static func recordHalts(
    _ decisions: [CutoffDecision], run: String, telemetry: BuildCutoffTelemetry?
  ) -> [String] {
    guard let telemetry, telemetry.enabled else { return [] }
    var notes: [String] = []
    func pair(_ task: String?, _ answer: BuildResumeAnswer) {
      do throws(BuildHaltLogError) {
        _ = try telemetry.log.halt(buildRun: run, task: task, reason: .budget)
        _ = try telemetry.log.resume(buildRun: run, task: task, answer: answer)
      } catch {
        notes.append("the cutoff's halt for \(task ?? "the run") wasn't recorded: \(error)")
      }
    }
    pair(nil, .continue)
    for decision in decisions {
      switch decision.action {
      case .finishMerge: pair(decision.task, .continue)
      case .abandon: pair(decision.task, .abandon)
      case .notStarted: continue
      }
    }
    return notes
  }

  static func render(_ result: BuildLoopResult<BuildCutoffReport>, format: OutputFormat) -> String {
    BuildLoop.render(result, format: format) { report in
      func list(_ ids: [String]) -> String { ids.isEmpty ? "none" : ids.joined(separator: ", ") }
      return "build cutoff: run \(report.runId); finish: \(list(report.finish)); abandoned: "
        + list(report.abandoned.map { "\($0.task) (\($0.reason))" })
        + "; never started: \(list(report.notStarted))"
    }
  }
}

/// Where `build cutoff` records its halts, and whether the repository keeps events.
struct BuildCutoffTelemetry {
  let log: BuildHaltLog
  let enabled: Bool
}

struct BuildCutoffCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "cutoff",
    abstract: "Decide a brownfield run's in-flight tasks at its time box's cutoff, asking no one.",
    discussion:
      "Brownfield runs only: an owned build halts and asks at its cutoff. Lets each task "
      + "already gating finish its merge while its before-merge qa (none when a GREEN run "
      + "covers its tip), that merge gate, `final` and the report still fit before the box "
      + "ends, each priced from this run's recorded merge and final gates and the fixed "
      + "estimates only before any, sets every other running task `abandoned` with the reason, "
      + "and writes "
      + "the decisions to the run's cutoff.json. It also acts once starts have stopped with "
      + "nothing running, naming the tasks that never started. It stops any gate still running "
      + "in an abandoned task's worktree and prunes the scratch trees of gates that ended "
      + "unfinished. A task whose merge is already "
      + "recorded always finishes, and one whose merge gate is recorded GREEN is listed under "
      + "`landed`, with only its post-merge steps left. Exits 0 when it decided, 1 "
      + "when --session doesn't hold the plan's lock or the cutoff hasn't come, and 2 for an "
      + "owned run, a missing --session or unreadable plan state.")

  @Argument(help: "The plan's slug.")
  var plan: String

  @Option(help: "The session id holding the plan's lock (from the SessionStart context).")
  var session: String?

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(
      filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let telemetry: BuildCutoffTelemetry?
    switch await BuildHaltRun.store(command: BuildCutoffRun.command) {
    case .found(let root, let enabled):
      telemetry = BuildCutoffTelemetry(log: BuildHaltLog(root: root), enabled: enabled)
    case .refused(let output):
      // The cutoff still decides; only its halts go unrecorded, and the report says so.
      FileHandle.standardError.write(Data(output.stderr.utf8))
      telemetry = nil
    }
    let result = await BuildCutoffRun.run(
      slug: plan, session: session, git: BuildLoop.git(), clock: LiveBuildClock(),
      telemetry: telemetry,
      leftovers: LiveRunLeftovers(directory: root),
      finalSeconds: MeasuredFinalGateReader.seconds(worktree: root),
      history: CutoffHistory(
        gateMilliseconds: MeasuredFinalGateReader.milliseconds(worktree: root),
        beforeMergeReports: QARunHistory.beforeMergeReports(worktree: root, plan: plan)))
    Console.write(BuildCutoffRun.render(result, format: output.format))
    try BuildLoop.exit(result)
  }
}

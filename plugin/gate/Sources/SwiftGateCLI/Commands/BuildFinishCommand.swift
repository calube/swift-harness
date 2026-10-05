import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

struct BuildFinishReport: Sendable, Equatable, Encodable {
  struct Unfinished: Sendable, Equatable, Encodable {
    let task: String
    let status: TaskStatus
  }

  let command: String
  let plan: String
  let indexStatus: PlanStatus
  let counts: [String: Int]
  let unfinished: [Unfinished]
  let resume: String
  /// The final run report page `build finish` wrote, relative to the checkout; `nil` when it
  /// wrote none.
  var runReport: String? = nil
  /// Why no run report page was written, or `nil` when one was.
  var runReportNote: String? = nil
  /// The `qa run --final` the finish read; `nil` for a plan with no validation table.
  var validation: Validation? = nil
  /// The final report's address on the repository's viewer server, which the finish stopped;
  /// `nil` when no server answered or the run has no final report.
  var viewerFinal: String? = nil

  struct Validation: Sendable, Equatable, Encodable {
    let runID: String
    let verdict: Verdict
    let message: String
  }
}

enum BuildFinishRun {
  /// - Parameters:
  ///   - root: the checkout whose state root holds the report; `nil` writes no report.
  ///   - pluginRoot: where `viewer/` lives.
  ///   - qaRun: the `qa run --final` id the caller read, from `--qa-run`.
  ///   - viewer: stops the repository's viewer server once the run's final report exists.
  static func run(
    slug: String, session: String?, git: any Git, clock: any BuildClock = LiveBuildClock(),
    root: URL? = nil, pluginRoot: URL? = nil, qaRun: String? = nil,
    viewer: ViewServerShutdown? = nil
  ) async
    -> BuildLoopResult<BuildFinishReport>
  {
    let command = "build finish"
    if let refusal: BuildLoopResult<BuildFinishReport> = await BuildLoop.authorize(
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
      let ledger = try BuildLoop.ledger(plan)
      let validation: BuildFinishReport.Validation?
      switch newestValidation(plan: plan, slug: slug, root: root, qaRun: qaRun) {
      case .success(let read): validation = read
      case .failure(let refusal): return .refused(command, slug, .red, refusal.message)
      }
      var counts: [String: Int] = [:]
      for task in ledger.tasks { counts[task.status.rawValue, default: 0] += 1 }
      let unfinished = ledger.tasks.filter { $0.status != .done }
        .map { BuildFinishReport.Unfinished(task: $0.id, status: $0.status) }
      let status: PlanStatus
      let resume: String
      if unfinished.isEmpty {
        status = .done
        resume = "build finished: all \(ledger.tasks.count) task(s) done"
      } else {
        status = .building
        resume =
          "build unfinished: "
          + unfinished.map { "\($0.task) (\($0.status.rawValue))" }.joined(separator: ", ")
          + "; resume with `swiftgate build next \(slug)`"
      }
      let run: BuildRunStore?
      do {
        run = try await BuildRunStore.latest(plan: slug, git: git)
        try await run?.append(
          .finish(
            BuildEvent.Finish(
              at: clock.now(), qaRun: validation?.runID, validation: validation?.verdict)))
      } catch {
        return .blocked(command, slug, "recording the build run's end: \(error)")
      }
      try await BuildLoop.setIndex(slug, status, resume: resume, git: git)
      var report = BuildFinishReport(
        command: command, plan: slug, indexStatus: status, counts: counts,
        unfinished: unfinished, resume: resume)
      report.validation = validation
      let message =
        resume
        + (validation.map {
          "; validation \($0.verdict.rawValue) in qa run \($0.runID): \($0.message)"
        } ?? "")
      if let root {
        (report.runReport, report.runReportNote) = await writeRunReport(
          run: run?.layout.runID, root: root, pluginRoot: pluginRoot, git: git, now: clock.now())
      }
      return BuildLoopResult(
        command: command, plan: slug, verdict: .green, report: report, holder: nil,
        message: message)
    } catch {
      return .blocked(command, slug, error.message)
    }
  }

  struct ValidationRefusal: Error {
    let message: String
  }

  /// The newest `qa run --final` of a brownfield plan with a validation table, once `qaRun` names
  /// it; `nil` for any other plan. A missing, older or non-final run refuses the finish, so the
  /// caller reads the verdict it ends on.
  static func newestValidation(
    plan: PlanStateLayout.Plan, slug: String, root: URL?, qaRun: String?
  ) -> Result<BuildFinishReport.Validation?, ValidationRefusal> {
    let files = FileManager.default
    guard files.fileExists(atPath: plan.directory + "/" + ValidationTable.fileName),
      (try? PlanStateStore(plan: plan).planFile())?.livePlanSource != nil
    else { return .success(nil) }
    let rerun =
      "run `swiftgate qa run --plan \(slug) --final` in the checkout, read its verdict, then "
      + "finish with `--qa-run <its run id>`"
    guard let root else {
      return .failure(ValidationRefusal(message: "no checkout to read the qa runs of; \(rerun)"))
    }
    let runs = RunStore(worktreeRoot: root).state.url(
      RunLayout.runsDirectory, directoryHint: .isDirectory)
    guard case .read(let newest) = QAFiles.newestWholeRun(plan: slug, runsDirectory: runs),
      let runID = newest.runID
    else {
      return .failure(
        ValidationRefusal(
          message: "\(slug) has a validation table but no qa run over every row; \(rerun)"))
    }
    let read = "the newest qa run, \(runID), is \(newest.verdict.rawValue): \(newest.message)"
    guard newest.final else {
      return .failure(
        ValidationRefusal(message: "\(read); it isn't --final, so no flow was recorded; \(rerun)"))
    }
    guard qaRun == runID else {
      let named = qaRun.map { "--qa-run names \($0), not it" } ?? "no --qa-run names it"
      return .failure(
        ValidationRefusal(
          message: "\(read); \(named). Read it, then finish with `--qa-run \(runID)`"))
    }
    return .success(
      BuildFinishReport.Validation(
        runID: runID, verdict: newest.verdict, message: newest.message))
  }

  /// The run's final report page, or why there is none. A page that can't be written never
  /// fails the finish: the report is a view.
  static func writeRunReport(
    run: String?, root: URL, pluginRoot: URL?, git: any Git, now: Date
  ) async -> (page: String?, note: String?) {
    guard let run else { return (nil, "no build run to report") }
    let common: String
    do {
      common = try await git.commonDirectory()
    } catch {
      return (nil, "the git common dir doesn't resolve: \(error)")
    }
    switch ReportRun.run(
      buildRun: run, format: .html, out: nil, root: root,
      commonDirectory: URL(filePath: common, directoryHint: .isDirectory),
      pluginRoot: pluginRoot, now: now)
    {
    case .wrote(let path): return (path, nil)
    case .printed: return (nil, "the report printed instead of writing a page")
    case .blocked(let message): return (nil, message)
    }
  }

  static func render(_ result: BuildLoopResult<BuildFinishReport>, format: OutputFormat) -> String {
    BuildLoop.render(result, format: format) { report in
      let tally = report.counts.keys.sorted().map { "\($0) \(report.counts[$0] ?? 0)" }
        .joined(separator: ", ")
      let page =
        report.runReport.map { "; report \($0)" } ?? report.runReportNote.map {
          "; no report: \($0)"
        } ?? ""
      return
        "build finish: index \(report.indexStatus.rawValue) (\(tally)); \(report.resume)\(page)"
    }
  }
}

struct BuildFinishCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "finish",
    abstract: "Print the run's final summary, and set the index to done or leave it building.",
    discussion:
      "Records the build run's end, sets the index to done when every ledger task is done, or "
      + "leaves it building with a resume note naming the unfinished tasks, and writes the run's "
      + "final report page. A brownfield plan with a validation table records the verdict of "
      + "the newest `qa run --final`, which --qa-run must name. Exits 0 either way, 1 when "
      + "--session doesn't hold the plan's lock or --qa-run doesn't name that run, and 2 for a "
      + "missing --session or unreadable plan state.")

  @Argument(help: "The plan's slug.")
  var plan: String

  @Option(help: "The session id holding the plan's lock (from the SessionStart context).")
  var session: String?

  @Option(
    help: ArgumentHelp(
      "The newest `qa run --final` id, whose verdict you read; a brownfield plan with a "
        + "validation table needs it."))
  var qaRun: String?

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let result = await BuildFinishRun.run(
      slug: plan, session: session, git: BuildLoop.git(),
      root: URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory),
      pluginRoot: ProcessInfo.processInfo.environment["SWIFTGATE_HARNESS_ROOT"].map {
        URL(filePath: $0, directoryHint: .isDirectory)
      }, qaRun: qaRun)
    Console.write(BuildFinishRun.render(result, format: output.format))
    try BuildLoop.exit(result)
  }
}

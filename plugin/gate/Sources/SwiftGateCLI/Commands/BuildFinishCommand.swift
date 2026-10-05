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
}

enum BuildFinishRun {
  /// - Parameters:
  ///   - root: the checkout whose state root holds the report; `nil` writes no report.
  ///   - pluginRoot: where `viewer/` lives.
  static func run(
    slug: String, session: String?, git: any Git, clock: any BuildClock = LiveBuildClock(),
    root: URL? = nil, pluginRoot: URL? = nil
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
        try await run?.append(.finish(BuildEvent.Finish(at: clock.now())))
      } catch {
        return .blocked(command, slug, "recording the build run's end: \(error)")
      }
      try await BuildLoop.setIndex(slug, status, resume: resume, git: git)
      var report = BuildFinishReport(
        command: command, plan: slug, indexStatus: status, counts: counts,
        unfinished: unfinished, resume: resume)
      if let root {
        (report.runReport, report.runReportNote) = await writeRunReport(
          run: run?.layout.runID, root: root, pluginRoot: pluginRoot, git: git, now: clock.now())
      }
      return BuildLoopResult(
        command: command, plan: slug, verdict: .green, report: report, holder: nil,
        message: resume)
    } catch {
      return .blocked(command, slug, error.message)
    }
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
      + "final report page. Exits 0 either way, 1 when --session doesn't "
      + "hold the plan's lock, and 2 for a missing --session or unreadable plan state.")

  @Argument(help: "The plan's slug.")
  var plan: String

  @Option(help: "The session id holding the plan's lock (from the SessionStart context).")
  var session: String?

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let result = await BuildFinishRun.run(
      slug: plan, session: session, git: BuildLoop.git(),
      root: URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory),
      pluginRoot: ProcessInfo.processInfo.environment["SWIFTGATE_HARNESS_ROOT"].map {
        URL(filePath: $0, directoryHint: .isDirectory)
      })
    Console.write(BuildFinishRun.render(result, format: output.format))
    try BuildLoop.exit(result)
  }
}

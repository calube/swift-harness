import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

enum BuildMergeRun {
  /// Acts only for the plan's lock holder, with the same `--session` check as the other build
  /// commands.
  static func run(
    slug: String, task: String, undo: Bool, fix: Bool = false, session: String?, git: any Git,
    workspace: any GitWorkspace, merger: any MergeRunner, clock: any BuildClock
  ) async -> BuildMergeReport {
    let command = undo ? BuildMerge.undoCommand : BuildMerge.mergeCommand
    if let refusal: BuildLoopResult<BuildMergeReport> = await BuildLoop.authorize(
      command, slug: slug, session: session, git: git)
    {
      return BuildMergeReport(
        command: command, plan: slug, task: task,
        status: refusal.verdict == .blocked ? .blocked : .notHeld, verdict: refusal.verdict,
        holder: refusal.holder, message: refusal.message)
    }
    let flow = BuildMerge(
      plan: slug, task: task, fix: fix, git: git, workspace: workspace, merger: merger, clock: clock
    )
    return undo ? await flow.undo() : await flow.merge()
  }

  static func render(_ report: BuildMergeReport, format: OutputFormat) -> String {
    switch format {
    case .json:
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      let data = (try? encoder.encode(report)) ?? Data()
      return String(decoding: data, as: UTF8.self)
    case .human:
      return "\(report.command): \(report.verdict.rawValue) \(report.message)"
    }
  }
}

struct BuildMergeCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "merge",
    abstract: "Merge a finished task's branch onto main, or undo a prior merge.",
    discussion:
      "Merges <plan>/<task> with --no-ff in the main checkout, which must be on a clean main at "
      + "the post commit of the build run's last merge event, and records the pre and post "
      + "commits. On a conflict it aborts, leaving main untouched, and cuts "
      + "../<repo>-<plan>-fix-<task> on <plan>/fix-<task> from main with the conflicted merge in "
      + "it. --undo resets main to the task's recorded pre commit, only while main is still at "
      + "its post commit, records an undo event, and cuts the same fix worktree with the task "
      + "merged in. --fix merges the fixer's branch <plan>/fix-<task> under the same checks and "
      + "records it as the task's merge. Exits 0 when "
      + "merged or undone; 1 on a conflict, when --session doesn't hold the plan's lock, or when "
      + "main isn't clean, on main, or where the last merge left it; 2 for a missing --session, "
      + "no build run, a damaged events log, or a failed git step.")

  @Argument(help: "The plan's slug.")
  var plan: String

  @Argument(help: "The task's id.")
  var task: String

  @Flag(help: "Undo the recorded merge instead of merging: reset main to the pre-merge commit.")
  var undo = false

  @Flag(help: "Merge the fixer's branch <plan>/fix-<task> instead of the task's branch.")
  var fix = false

  mutating func validate() throws {
    if undo && fix { throw ValidationError("--undo and --fix can't be combined") }
  }

  @Option(help: "The session id holding the plan's lock (from the SessionStart context).")
  var session: String?

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = FileManager.default.currentDirectoryPath
    let runner = LiveProcessRunner()
    let report = await BuildMergeRun.run(
      slug: plan, task: task, undo: undo, fix: fix, session: session,
      git: LiveGit(runner: runner, repositoryRoot: root),
      workspace: LiveGitWorkspace(runner: runner, repositoryRoot: root),
      merger: LiveMergeRunner(runner: runner), clock: LiveBuildClock())
    Console.write(BuildMergeRun.render(report, format: output.format))
    if report.verdict != .green { throw ExitCode(report.verdict.exitCode) }
  }
}

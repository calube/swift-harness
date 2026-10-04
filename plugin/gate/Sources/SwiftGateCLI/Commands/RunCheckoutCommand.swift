import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// `run checkout create` and `remove`: the brownfield plan branch's own checkout, where the run's
/// contract commit lands, merges land and the run's gates run. Both act only for the session
/// holding the plan's lock.
enum RunCheckoutRun {
  static func create(slug: String, session: String?, root: URL, runner: any ProcessRunner)
    async -> WorktreeReport
  {
    let context: Context
    switch await Context.resolve(
      "run checkout create", slug: slug, session: session, root: root, runner: runner)
    {
    case .success(let resolved): context = resolved
    case .failure(let refusal): return refusal.report
    }
    let workspace = LiveGitWorkspace(runner: runner, repositoryRoot: root.path)
    if FileManager.default.fileExists(atPath: context.path) {
      return context.report(.refused, .red, "\(context.path) already exists")
    }
    do throws(GitWorkspaceError) {
      guard try await workspace.branchExists(context.branch) else {
        return context.report(
          .refused, .red,
          "branch \(context.branch) doesn't exist; `swiftgate run` creates it at launch")
      }
      try await workspace.checkOutWorktree(at: context.path, branch: context.branch)
    } catch {
      return context.report(.blocked, .blocked, "\(error)")
    }
    return context.report(.created, .green, "created \(context.path) on \(context.branch)")
  }

  /// Copies the checkout's gate reports, and any events it kept itself, into the user's
  /// checkout first, so they outlive it. The plan branch stays: it holds the run.
  static func remove(slug: String, session: String?, root: URL, runner: any ProcessRunner)
    async -> WorktreeReport
  {
    let context: Context
    switch await Context.resolve(
      "run checkout remove", slug: slug, session: session, root: root, runner: runner)
    {
    case .success(let resolved): context = resolved
    case .failure(let refusal): return refusal.report
    }
    guard FileManager.default.fileExists(atPath: context.path) else {
      return context.report(.refused, .red, "no plan checkout at \(context.path)")
    }
    let main: String
    do throws(GitWorkspaceError) {
      main = try TaskWorktree.mainCheckout(commonDirectory: context.common)
    } catch {
      return context.report(.blocked, .blocked, "\(error)")
    }
    let keeping = WorktreeRun.keepRuns(from: context.path, into: main)
    let events = WorktreeRun.copyEvents(
      from: context.path, into: main, commonDirectory: context.common)
    do throws(GitWorkspaceError) {
      try await LiveGitWorkspace(runner: runner, repositoryRoot: root.path)
        .removeWorktree(at: context.path, force: false)
    } catch {
      return context.report(.blocked, .blocked, "\(error)" + keeping.message + events.message)
    }
    var report = context.report(
      .removed, .green,
      "removed \(context.path); \(context.branch) stays" + keeping.message + events.message)
    report.keptRuns = keeping.kept
    report.unkeptRuns = keeping.unkept.isEmpty ? nil : keeping.unkept
    report.events = events.copied
    report.unkeptEvents = events.unkept
    return report
  }

  /// A brownfield plan the caller holds the lock for, and where its checkout goes.
  private struct Context {
    struct Refusal: Error {
      let report: WorktreeReport
    }

    let command: String
    let slug: String
    let common: String
    let path: String
    let branch: String

    static func resolve(
      _ command: String, slug: String, session: String?, root: URL, runner: any ProcessRunner
    ) async
      -> Result<Context, Refusal>
    {
      func refuse(
        _ status: WorktreeReport.Status, _ verdict: Verdict, _ message: String,
        holder: String? = nil
      ) -> Result<Context, Refusal> {
        .failure(
          Refusal(
            report: WorktreeReport(
              command: command, plan: slug, task: nil, status: status, verdict: verdict,
              holder: holder, worktree: nil, branch: nil, cloned: nil, missing: nil,
              message: message)))
      }
      guard let session else {
        return refuse(
          .blocked, .blocked, "--session is required: pass the id from the SessionStart context")
      }
      guard PlanLock.isValidSession(session) else {
        return refuse(.blocked, .blocked, "--session must be a non-empty id without whitespace")
      }
      guard StateRootResolver.brownfieldLayout(worktree: root) != nil else {
        return refuse(
          .blocked, .blocked,
          "\(root.path) is not in a brownfield clone: its git common dir has no "
            + StateRootResolver.commonConfigFile)
      }
      let common: String
      do {
        common = try await LiveGit(runner: runner, repositoryRoot: root.path).commonDirectory()
      } catch {
        return refuse(.blocked, .blocked, "can't find the git common dir: \(error)")
      }
      let plan: PlanStateLayout.Plan
      let path: String
      do {
        plan = try PlanStateLayout(commonDirectory: common).plan(slug)
        path = try TaskWorktree.planCheckout(commonDirectory: common, plan: slug)
      } catch {
        return refuse(.blocked, .blocked, "invalid plan name `\(slug)`: \(error)")
      }
      let holder: String?
      do {
        holder = try PlanLock(plan: plan).holder()
      } catch {
        return refuse(.blocked, .blocked, "can't read \(plan.orchestratorLock): \(error)")
      }
      guard let holder, holder == session else {
        return refuse(
          .notHeld, .red,
          holder.map { PlanLockRun.heldByOtherMessage(slug, $0) }
            ?? "plan `\(slug)` isn't claimed; only the session holding its lock acts on it. "
            + "Claim it with `swiftgate plan claim \(slug) --session <id>` first.",
          holder: holder)
      }
      return .success(
        Context(
          command: command, slug: slug, common: common, path: path,
          branch: BrownfieldRunReport.planBranch(slug: slug)))
    }

    func report(_ status: WorktreeReport.Status, _ verdict: Verdict, _ message: String)
      -> WorktreeReport
    {
      WorktreeReport(
        command: command, plan: slug, task: nil, status: status, verdict: verdict, holder: nil,
        worktree: path, branch: branch, cloned: nil, missing: nil, message: message)
    }
  }
}

struct RunCheckoutCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "checkout",
    abstract: "Create or remove a brownfield plan's checkout of its plan branch.",
    subcommands: [RunCheckoutCreateCommand.self, RunCheckoutRemoveCommand.self])
}

struct RunCheckoutCreateCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "create",
    abstract: "Check out a brownfield plan's branch in the plan's own checkout.",
    discussion:
      "Adds the worktree build merge lands merges in, on the plan branch swift-harness/<plan>, "
      + "and prints its path. Gates there write their events to the clone's shared store. Exits "
      + "0 when created; 1 when this session doesn't hold the plan's lock, the checkout exists "
      + "or the plan branch doesn't; 2 for a missing --session, a clone that isn't brownfield, or "
      + "a failed git step.")

  @Argument(help: "The plan's slug.")
  var plan: String

  @Option(help: "The session id holding the plan's lock (from the SessionStart context).")
  var session: String?

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let report = await RunCheckoutRun.create(
      slug: plan, session: session, root: root, runner: LiveProcessRunner())
    Console.write(WorktreeRun.render(report, format: output.format))
    if report.verdict != .green { throw ExitCode(report.verdict.exitCode) }
  }
}

struct RunCheckoutRemoveCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "remove",
    abstract: "Remove a brownfield plan's checkout, keeping its gate reports.",
    discussion:
      "Copies each gate run under the checkout's runs/ into the user's checkout, and any events "
      + "the checkout kept itself into its events/imported/<storeID>/, then removes the "
      + "checkout. The plan branch stays. Exits 0 when removed; 1 when this session doesn't hold "
      + "the plan's lock or there is no checkout; 2 for a missing --session, a clone that isn't "
      + "brownfield, or a failed git step, such as a checkout with uncommitted changes.")

  @Argument(help: "The plan's slug.")
  var plan: String

  @Option(help: "The session id holding the plan's lock (from the SessionStart context).")
  var session: String?

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let report = await RunCheckoutRun.remove(
      slug: plan, session: session, root: root, runner: LiveProcessRunner())
    Console.write(WorktreeRun.render(report, format: output.format))
    if report.verdict != .green { throw ExitCode(report.verdict.exitCode) }
  }
}

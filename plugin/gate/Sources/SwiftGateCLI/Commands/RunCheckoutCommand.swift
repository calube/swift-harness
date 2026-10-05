import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// `run checkout create` and `remove`: the brownfield plan branch's own checkout, where the run's
/// contract commit lands, merges land and the run's gates run. Both act only for the session
/// holding the plan's lock.
enum RunCheckoutRun {
  static func create(
    slug: String, session: String?, root: URL, runner: any ProcessRunner,
    install: WorktreeNodeInstall.Dependencies = .live()
  ) async -> WorktreeReport {
    let context: Context
    switch await Context.resolve(
      "run checkout create", slug: slug, session: session, root: root, runner: runner)
    {
    case .success(let resolved): context = resolved
    case .failure(let refusal): return refusal.report
    }
    let workspace = LiveGitWorkspace(runner: runner, repositoryRoot: root.path)
    let made: Bool
    if FileManager.default.fileExists(atPath: context.path) {
      // `swiftgate run` checks the plan branch out at launch, for the warm-up to build in.
      guard await isCheckout(context.path, on: context.branch, root: root, runner: runner) else {
        return context.report(
          .refused, .red, "\(context.path) already exists and isn't \(context.branch)'s checkout")
      }
      made = false
    } else {
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
      made = true
    }
    let installed = await WorktreeNodeInstall.run(worktree: context.path, dependencies: install)
    var report = context.report(
      .created, .green,
      (made
        ? "created \(context.path) on \(context.branch)"
        : "\(context.path) is already \(context.branch)'s checkout, made by `swiftgate run`")
        + installed.message)
    report.installs = installed.installs.isEmpty ? nil : installed.installs
    report.installNotes = installed.notes.isEmpty ? nil : installed.notes
    return report
  }

  /// Whether `git worktree list` names `path` as a worktree with `branch` checked out.
  private static func isCheckout(
    _ path: String, on branch: String, root: URL, runner: any ProcessRunner
  ) async -> Bool {
    guard
      let output = try? await runner.run(
        ProcessInvocation(
          executable: "git", arguments: ["worktree", "list", "--porcelain"],
          workingDirectory: root.path, timeout: .seconds(60))),
      output.status.isSuccess
    else { return false }
    let wanted = CanonicalPath.of(URL(filePath: path, directoryHint: .isDirectory))
    return output.stdout.text.components(separatedBy: "\n\n").contains { entry in
      let lines = entry.split(separator: "\n").map(String.init)
      guard let worktree = lines.first(where: { $0.hasPrefix("worktree ") }) else { return false }
      let named = CanonicalPath.of(
        URL(filePath: String(worktree.dropFirst("worktree ".count)), directoryHint: .isDirectory))
      return named == wanted && lines.contains("branch refs/heads/\(branch)")
    }
  }

  /// Copies the checkout's gate and `qa run` directories into the clone's kept runs, where the run
  /// viewer reads them, and any events it kept itself into the user's checkout first, so they
  /// outlive it. The plan branch stays: it holds the run.
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
    let kept =
      StateRootResolver.keptRuns(
        commonDir: URL(filePath: context.common, directoryHint: .isDirectory))
      ?? StateRootResolver.resolve(worktree: URL(filePath: main, directoryHint: .isDirectory))
    let keeping = WorktreeRun.keepRuns(from: context.path, into: kept)
    let events = WorktreeRun.copyEvents(
      from: context.path, into: main, commonDirectory: context.common)
    let workspace = LiveGitWorkspace(runner: runner, repositoryRoot: root.path)
    do throws(GitWorkspaceError) {
      try await workspace.removeWorktree(at: context.path, force: false)
    } catch {
      return context.report(.blocked, .blocked, "\(error)" + keeping.message + events.message)
    }
    let left = await removeTaskWorktrees(
      context, kept: kept, main: main, workspace: workspace)
    var report = context.report(
      left.verdict == .green ? .removed : .blocked, left.verdict,
      "removed \(context.path); \(context.branch) stays" + keeping.message + events.message
        + left.message)
    report.keptRuns = keeping.kept + left.keptRuns
    let unkept = keeping.unkept + left.unkeptRuns
    report.unkeptRuns = unkept.isEmpty ? nil : unkept
    report.events = events.copied
    report.unkeptEvents = events.unkept
    report.discarded = left.discarded
    report.keptBranches = left.keptBranches
    return report
  }

  /// What the removal did with the task and fix worktrees the run left.
  private struct LeftWorktrees {
    var discarded: [String] = []
    var keptBranches: [String] = []
    var keptRuns: [String] = []
    var unkeptRuns: [WorktreeReport.UnkeptRun] = []
    var message = ""
    var verdict = Verdict.green
  }

  /// Removes each ledger task's worktree and its fix worktree still on disk, merged or not, as
  /// `worktree remove --abandoned` does: their runs and events are kept first, uncommitted edits
  /// go, and both branches stay so every commit stays reachable. The run has ended, so nothing
  /// works in them any more.
  private static func removeTaskWorktrees(
    _ context: Context, kept: StateRoot, main: String, workspace: LiveGitWorkspace
  ) async -> LeftWorktrees {
    var left = LeftWorktrees()
    let tasks: [String]
    do {
      let plan = try PlanStateLayout(commonDirectory: context.common).plan(context.slug)
      tasks = try PlanStateStore(plan: plan).ledger().tasks.map(\.id)
    } catch {
      left.message = "; the ledger can't be read (\(error)), so no task worktree was removed"
      return left
    }
    for task in tasks {
      for name in [task, "fix-\(task)"] {
        let names: TaskWorktree
        do throws(GitWorkspaceError) {
          names = try TaskWorktree(
            commonDirectory: context.common, plan: context.slug, task: name, profile: .brownfield)
        } catch {
          continue
        }
        do throws(GitWorkspaceError) {
          if try await workspace.branchExists(names.branch) {
            left.keptBranches.append(names.branch)
          }
          guard FileManager.default.fileExists(atPath: names.path) else { continue }
          let runs = WorktreeRun.keepRuns(from: names.path, into: kept)
          let events = WorktreeRun.copyEvents(
            from: names.path, into: main, commonDirectory: context.common)
          left.keptRuns += runs.kept
          left.unkeptRuns += runs.unkept
          left.message += runs.message + events.message
          try await workspace.removeWorktree(at: names.path, force: true)
          left.discarded.append(names.path)
        } catch {
          left.message += "; \(names.path) wasn't removed: \(error)"
          left.verdict = .blocked
        }
      }
    }
    if !left.discarded.isEmpty {
      left.message +=
        "; removed \(left.discarded.joined(separator: ", ")), keeping branches "
        + left.keptBranches.joined(separator: ", ")
    }
    return left
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
      + "or takes the one `swiftgate run` checked out at launch, and prints its path, then installs each node area's dependencies there once, frozen to "
      + "its lockfile; a failed install is a report line and leaves the checkout created. Gates "
      + "there write their events to the clone's shared store. Exits "
      + "0 when created or taken; 1 when this session doesn't hold the plan's lock, the path holds "
      + "something other than the plan branch's checkout, or the plan branch doesn't exist; 2 for a missing --session, a clone that isn't brownfield, or "
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
      + "checkout, then every task and fix worktree the plan's tasks left, merged or not, the "
      + "same way. The plan branch and every task and fix branch stay. Exits 0 when removed; 1 "
      + "when this session doesn't hold the plan's lock or there is no checkout; 2 for a missing "
      + "--session, a clone that isn't brownfield, or a failed git step, such as a checkout with "
      + "uncommitted changes.")

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

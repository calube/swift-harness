import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

struct WorktreeCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "worktree",
    abstract: "Create, warm-check, and remove a build task's git worktree.",
    subcommands: [
      WorktreeCreateCommand.self, WorktreeWarmCheckCommand.self, WorktreeRemoveCommand.self,
    ])
}

/// What a `worktree` subcommand did.
struct WorktreeReport: Sendable, Equatable, Encodable {
  enum Status: String, Sendable, Encodable {
    case created
    case removed
    /// At least one package `.build` exists to clone.
    case warm
    /// No package `.build` exists; a new worktree would build from scratch.
    case cold
    /// The lock is free or another session holds it; nothing changed.
    case notHeld = "not-held"
    /// The request conflicts with the plan or the repository; nothing changed.
    case refused
    case blocked
  }

  let command: String
  let plan: String?
  let task: String?
  let status: Status
  let verdict: Verdict
  /// The session holding the lock when it isn't the caller.
  let holder: String?
  let worktree: String?
  let branch: String?
  /// Checkout-relative directories cloned (`create`) or there to clone (`warm-check`).
  let cloned: [String]?
  /// Package `.build` directories the main checkout doesn't have.
  let missing: [String]?
  let message: String
}

/// The testable core of the `worktree` subcommands. `create` and `remove` act only for the plan's
/// lock holder, with the same `--session` check as `plan set`.
enum WorktreeRun {
  static func create(
    slug: String, task: String, session: String?, git: any Git, workspace: any GitWorkspace
  ) async -> WorktreeReport {
    let command = "worktree create"
    let context: HeldTask
    switch await HeldTask.resolve(command, slug: slug, task: task, session: session, git: git) {
    case .success(let resolved): context = resolved
    case .failure(let refusal): return refusal.report
    }
    let names = context.names
    let report = Reporter(command: command, slug: slug, task: task, names: names)

    let survey: WarmBuild.Survey
    switch surveyWarmBuild(mainCheckout: names.mainCheckout) {
    case .success(let found): survey = found
    case .failure(let problem): return report.blocked(problem.message)
    }
    if FileManager.default.fileExists(atPath: names.path) {
      return report.refused("\(names.path) already exists; remove it or pick another task")
    }
    do throws(GitWorkspaceError) {
      if try await workspace.branchExists(names.branch) {
        return report.refused("branch \(names.branch) already exists")
      }
      try await workspace.addWorktree(
        at: names.path, branch: names.branch, from: TaskWorktree.base)
    } catch {
      return report.blocked("\(error)")
    }

    let cloned: [String]
    do throws(GitWorkspaceError) {
      cloned = try await workspace.cloneWarmBuild(
        survey.clonable, from: names.mainCheckout, into: names.path)
    } catch {
      let undone = await report.undo(workspace: workspace)
      return report.blocked("\(error); \(undone)")
    }
    // Checked again: the lock may have changed hands while the clone ran.
    switch context.recordBranch() {
    case .success: break
    case .failure(let refusal):
      let undone = await report.undo(workspace: workspace)
      let refused = refusal.report
      return WorktreeReport(
        command: refused.command, plan: refused.plan, task: refused.task,
        status: refused.status, verdict: refused.verdict, holder: refused.holder,
        worktree: nil, branch: nil, cloned: nil, missing: nil,
        message: "\(refused.message); \(undone)")
    }
    let missing =
      survey.missingPackageBuilds.isEmpty
      ? "" : "; no warm build for \(survey.missingPackageBuilds.joined(separator: ", "))"
    return WorktreeReport(
      command: command, plan: slug, task: task, status: .created, verdict: .green, holder: nil,
      worktree: names.path, branch: names.branch, cloned: cloned,
      missing: survey.missingPackageBuilds,
      message: "created \(names.path) on \(names.branch), cloned "
        + (cloned.isEmpty ? "nothing" : cloned.joined(separator: ", ")) + missing)
  }

  static func warmCheck(git: any Git) async -> WorktreeReport {
    let command = "worktree warm-check"
    let report = Reporter(command: command, slug: nil, task: nil, names: nil)
    let mainCheckout: String
    do {
      mainCheckout = try TaskWorktree.mainCheckout(commonDirectory: try await git.commonDirectory())
    } catch {
      return report.blocked("can't find the main checkout: \(error)")
    }
    let survey: WarmBuild.Survey
    switch surveyWarmBuild(mainCheckout: mainCheckout) {
    case .success(let found): survey = found
    case .failure(let problem): return report.blocked(problem.message)
    }
    guard !survey.packageBuilds.isEmpty else {
      return WorktreeReport(
        command: command, plan: nil, task: nil, status: .cold, verdict: .red, holder: nil,
        worktree: nil, branch: nil, cloned: [], missing: survey.missingPackageBuilds,
        message: "no warm build in \(mainCheckout) to clone: missing "
          + survey.missingPackageBuilds.joined(separator: ", ")
          + ". Build each package there first (`swift build --build-tests`).")
    }
    let missing =
      survey.missingPackageBuilds.isEmpty
      ? "" : "; missing \(survey.missingPackageBuilds.joined(separator: ", "))"
    return WorktreeReport(
      command: command, plan: nil, task: nil, status: .warm, verdict: .green, holder: nil,
      worktree: nil, branch: nil, cloned: survey.clonable, missing: survey.missingPackageBuilds,
      message: "warm build to clone: \(survey.clonable.joined(separator: ", "))\(missing)")
  }

  static func remove(
    slug: String, task: String, session: String?, git: any Git, workspace: any GitWorkspace
  ) async -> WorktreeReport {
    let command = "worktree remove"
    let context: HeldTask
    switch await HeldTask.resolve(command, slug: slug, task: task, session: session, git: git) {
    case .success(let resolved): context = resolved
    case .failure(let refusal): return refusal.report
    }
    let names = context.names
    let report = Reporter(command: command, slug: slug, task: task, names: names)
    do throws(GitWorkspaceError) {
      guard try await workspace.branchExists(names.branch) else {
        return report.refused("branch \(names.branch) doesn't exist")
      }
      guard try await workspace.isMerged(names.branch, into: TaskWorktree.base) else {
        return report.refused(
          "branch \(names.branch) isn't merged into \(TaskWorktree.base); merge it first")
      }
      if FileManager.default.fileExists(atPath: names.path) {
        try await workspace.removeWorktree(at: names.path, force: false)
      }
      try await workspace.deleteBranch(names.branch)
    } catch {
      return report.blocked("\(error)")
    }
    return WorktreeReport(
      command: command, plan: slug, task: task, status: .removed, verdict: .green, holder: nil,
      worktree: names.path, branch: names.branch, cloned: nil, missing: nil,
      message: "removed \(names.path) and branch \(names.branch)")
  }

  static func render(_ report: WorktreeReport, format: OutputFormat) -> String {
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

  struct Problem: Error {
    let message: String
  }

  /// The main checkout's configured packages and which of their builds exist there.
  private static func surveyWarmBuild(mainCheckout: String) -> Result<WarmBuild.Survey, Problem> {
    let root = URL(filePath: mainCheckout, directoryHint: .isDirectory)
    let config: Config
    do throws(ConfigLoadError) {
      guard let loaded = try ConfigLoader().load(repositoryRoot: root) else {
        return .failure(Problem(message: "no \(ConfigLoader.fileName) in \(mainCheckout)"))
      }
      config = loaded
    } catch {
      return .failure(Problem(message: "\(ConfigLoader.fileName) in \(mainCheckout): \(error)"))
    }
    do throws(ModuleGraphLoadError) {
      let packages = try PackageDirectories.resolve(globs: config.packages, root: root)
      return .success(WarmBuild.survey(packageDirectories: packages, in: mainCheckout))
    } catch {
      return .failure(Problem(message: "\(error)"))
    }
  }
}

/// A task of a plan the caller holds the lock for, and the ledger it's in.
private struct HeldTask {
  struct Refusal: Error {
    let report: WorktreeReport
  }

  let command: String
  let slug: String
  let task: String
  let session: String
  let store: PlanStateStore
  let names: TaskWorktree

  static func resolve(
    _ command: String, slug: String, task: String, session: String?, git: any Git
  ) async -> Result<HeldTask, Refusal> {
    let report = Reporter(command: command, slug: slug, task: task, names: nil)
    guard let session else {
      return .failure(
        Refusal(
          report: report.blocked("--session is required: pass the id from the SessionStart context")
        ))
    }
    guard PlanLock.isValidSession(session) else {
      return .failure(
        Refusal(report: report.blocked("--session must be a non-empty id without whitespace")))
    }
    let common: String
    do {
      common = try await git.commonDirectory()
    } catch {
      return .failure(Refusal(report: report.blocked("can't find the git common dir: \(error)")))
    }
    let store: PlanStateStore
    let names: TaskWorktree
    do {
      store = PlanStateStore(plan: try PlanStateLayout(commonDirectory: common).plan(slug))
    } catch {
      return .failure(Refusal(report: report.blocked("invalid plan name `\(slug)`: \(error)")))
    }
    do throws(GitWorkspaceError) {
      names = try TaskWorktree(commonDirectory: common, plan: slug, task: task)
    } catch {
      return .failure(Refusal(report: report.blocked("\(error)")))
    }
    let held = HeldTask(
      command: command, slug: slug, task: task, session: session, store: store, names: names)
    if let refusal = held.checkHolder() { return .failure(refusal) }
    switch held.ledger() {
    case .failure(let refusal): return .failure(refusal)
    case .success(let ledger):
      guard ledger.tasks.contains(where: { $0.id == task }) else {
        return .failure(
          Refusal(report: report.refused("task `\(task)` isn't in plan `\(slug)`'s ledger")))
      }
    }
    return .success(held)
  }

  private var report: Reporter {
    Reporter(command: command, slug: slug, task: task, names: names)
  }

  func checkHolder() -> Refusal? {
    let lock = PlanLock(plan: store.plan)
    let holder: String?
    do {
      holder = try lock.holder()
    } catch {
      return Refusal(report: report.blocked("can't read \(store.plan.orchestratorLock): \(error)"))
    }
    guard let holder, holder == session else {
      return Refusal(
        report: WorktreeReport(
          command: command, plan: slug, task: task, status: .notHeld, verdict: .red,
          holder: holder, worktree: nil, branch: nil, cloned: nil, missing: nil,
          message: holder.map { PlanLockRun.heldByOtherMessage(slug, $0) }
            ?? "plan `\(slug)` isn't claimed; only the session holding its lock acts on it. "
            + "Claim it with `swiftgate plan claim \(slug) --session <id>` first."))
    }
    return nil
  }

  func ledger() -> Result<Ledger, Refusal> {
    do throws(PlanStateStoreError) {
      return .success(try store.ledger())
    } catch {
      return .failure(Refusal(report: report.blocked("reading the ledger: \(error)")))
    }
  }

  /// Sets this task's `branch` and nothing else, rewriting `ledger.json` whole.
  func recordBranch() -> Result<Void, Refusal> {
    if let refusal = checkHolder() { return .failure(refusal) }
    let current: Ledger
    switch ledger() {
    case .success(let read): current = read
    case .failure(let refusal): return .failure(refusal)
    }
    let tasks = current.tasks.map { entry in
      guard entry.id == task else { return entry }
      return LedgerTask(
        id: entry.id, deps: entry.deps, writeSet: entry.writeSet, gate: entry.gate,
        tests: entry.tests, covers: entry.covers, estLines: entry.estLines,
        status: entry.status, worktree: entry.worktree, actualLines: entry.actualLines,
        model: entry.model, branch: names.branch)
    }
    let updated = Ledger(
      schemaVersion: current.schemaVersion, resume: current.resume,
      maxParallel: current.maxParallel, tasks: tasks, waves: current.waves)
    do {
      // Written beside the old file and renamed over it: a reader sees one whole file or the other.
      try LedgerJSON.encode(updated).write(
        to: URL(filePath: store.plan.ledgerFile), options: .atomic)
    } catch {
      return .failure(
        Refusal(report: report.blocked("writing \(store.plan.ledgerFile): \(error)")))
    }
    return .success(())
  }
}

private struct Reporter {
  let command: String
  let slug: String?
  let task: String?
  let names: TaskWorktree?

  func blocked(_ message: String) -> WorktreeReport {
    make(.blocked, .blocked, message)
  }

  func refused(_ message: String) -> WorktreeReport {
    make(.refused, .red, message)
  }

  /// Undoes a half-made `create` so a retry isn't refused for the branch and path it left.
  /// - Returns: what was undone, for the report.
  func undo(workspace: any GitWorkspace) async -> String {
    guard let names else { return "nothing to undo" }
    do throws(GitWorkspaceError) {
      try await workspace.removeWorktree(at: names.path, force: true)
      try await workspace.deleteBranch(names.branch)
    } catch {
      return "couldn't remove the new worktree and branch: \(error)"
    }
    return "removed the new worktree and branch"
  }

  private func make(_ status: WorktreeReport.Status, _ verdict: Verdict, _ message: String)
    -> WorktreeReport
  {
    WorktreeReport(
      command: command, plan: slug, task: task, status: status, verdict: verdict, holder: nil,
      worktree: names?.path, branch: names?.branch, cloned: nil, missing: nil, message: message)
  }
}

struct WorktreeCreateCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "create",
    abstract:
      "Add a git worktree on the task's branch, clone the warm build into it, and record the "
      + "branch under the plan lock.",
    discussion:
      "Adds ../<repo>-<plan>-<task> beside the main checkout on branch <plan>/<task> from main, "
      + "APFS-clones every configured package's .build and the DerivedData under .harness/, "
      + "deletes each cloned module cache, and sets the task's branch in the ledger. Exits 0 when "
      + "created; 1 when this session doesn't hold the plan's lock, the task isn't in the ledger, "
      + "or the worktree path or branch exists; 2 for a missing flag, an unreadable ledger or "
      + "config, or a failed git or clone step (the new worktree and branch are then removed).")

  @Argument(help: "The plan's slug.")
  var plan: String

  @Argument(help: "The task's id.")
  var task: String

  @Option(help: "The session id holding the plan's lock (from the SessionStart context).")
  var session: String?

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = FileManager.default.currentDirectoryPath
    let runner = LiveProcessRunner()
    let report = await WorktreeRun.create(
      slug: plan, task: task, session: session,
      git: LiveGit(runner: runner, repositoryRoot: root),
      workspace: LiveGitWorkspace(runner: runner, repositoryRoot: root))
    Console.write(WorktreeRun.render(report, format: output.format))
    if report.verdict != .green { throw ExitCode(report.verdict.exitCode) }
  }
}

struct WorktreeWarmCheckCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "warm-check",
    abstract: "Fail when no warm build exists for worktree create to clone.",
    discussion:
      "Looks in the main checkout for each configured package's .build. Exits 0 when at least "
      + "one exists, 1 when none does (naming them), and 2 when the config or git can't be read.")

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = FileManager.default.currentDirectoryPath
    let report = await WorktreeRun.warmCheck(
      git: LiveGit(runner: LiveProcessRunner(), repositoryRoot: root))
    Console.write(WorktreeRun.render(report, format: output.format))
    if report.verdict != .green { throw ExitCode(report.verdict.exitCode) }
  }
}

struct WorktreeRemoveCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "remove",
    abstract: "Remove a merged task's worktree and branch.",
    discussion:
      "Exits 0 when removed; 1 when this session doesn't hold the plan's lock, the task isn't in "
      + "the ledger, or its branch is missing or not merged into main; 2 for a missing flag or a "
      + "failed git step, such as a worktree with uncommitted changes.")

  @Argument(help: "The plan's slug.")
  var plan: String

  @Argument(help: "The task's id.")
  var task: String

  @Option(help: "The session id holding the plan's lock (from the SessionStart context).")
  var session: String?

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = FileManager.default.currentDirectoryPath
    let runner = LiveProcessRunner()
    let report = await WorktreeRun.remove(
      slug: plan, task: task, session: session,
      git: LiveGit(runner: runner, repositoryRoot: root),
      workspace: LiveGitWorkspace(runner: runner, repositoryRoot: root))
    Console.write(WorktreeRun.render(report, format: output.format))
    if report.verdict != .green { throw ExitCode(report.verdict.exitCode) }
  }
}

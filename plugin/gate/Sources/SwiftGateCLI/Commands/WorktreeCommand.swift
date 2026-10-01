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
  /// `remove`: the worktree's run ids copied into the main checkout's `.harness/runs/`.
  var keptRuns: [String]? = nil
  /// `remove`: runs it couldn't copy, which the removal then deleted. Absent when there are none.
  var unkeptRuns: [UnkeptRun]? = nil
  /// `remove`: the worktree's event store as the main checkout now holds it. Absent when the
  /// worktree had no events or the copy failed.
  var events: CopiedEvents? = nil
  /// `remove`: why the worktree's events couldn't be copied, and where they were moved instead,
  /// or why that failed too and they were lost.
  var unkeptEvents: UnkeptEvents? = nil

  struct UnkeptRun: Sendable, Equatable, Encodable {
    let runId: String
    let reason: String
  }

  struct UnkeptEvents: Sendable, Equatable, Encodable {
    let copyError: String
    /// Where the worktree's `.harness/events/` was moved whole; `nil` when it wasn't.
    let movedTo: String?
    /// Why the move failed too, so the events were removed with the worktree.
    let moveError: String?
  }

  struct CopiedEvents: Sendable, Equatable, Encodable {
    let storeID: String
    /// Checkout-relative: `.harness/events/imported/<storeID>`.
    let path: String
    let bytes: Int
    /// `false` when an earlier copy with at least as many bytes was kept instead.
    let copied: Bool
  }
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
    switch await context.recordBranch() {
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
    slug: String, task: String, fix: Bool = false, session: String?, git: any Git,
    workspace: any GitWorkspace
  ) async -> WorktreeReport {
    let command = "worktree remove"
    let context: HeldTask
    switch await HeldTask.resolve(command, slug: slug, task: task, session: session, git: git) {
    case .success(let resolved): context = resolved
    case .failure(let refusal): return refusal.report
    }
    let names: TaskWorktree
    if fix {
      // The fix worktree `build merge` cuts for this task, named the way it names it.
      do {
        names = try TaskWorktree(
          commonDirectory: try await git.commonDirectory(), plan: slug, task: "fix-\(task)")
      } catch {
        return Reporter(command: command, slug: slug, task: task, names: nil).blocked(
          "\(error)")
      }
    } else {
      names = context.names
    }
    let report = Reporter(command: command, slug: slug, task: task, names: names)
    var keeping = KeptRuns()
    var events = KeptEvents()
    do throws(GitWorkspaceError) {
      guard try await workspace.branchExists(names.branch) else {
        return report.refused("branch \(names.branch) doesn't exist")
      }
      guard try await workspace.isMerged(names.branch, into: TaskWorktree.base) else {
        return report.refused(
          "branch \(names.branch) isn't merged into \(TaskWorktree.base); merge it first")
      }
      if FileManager.default.fileExists(atPath: names.path) {
        keeping = keepRuns(of: names)
        events = copyEvents(of: names)
        try await workspace.removeWorktree(at: names.path, force: false)
      }
      try await workspace.deleteBranch(names.branch)
    } catch {
      return report.blocked("\(error)")
    }
    return WorktreeReport(
      command: command, plan: slug, task: task, status: .removed, verdict: .green, holder: nil,
      worktree: names.path, branch: names.branch, cloned: nil, missing: nil,
      message: "removed \(names.path) and branch \(names.branch)" + keeping.message
        + events.message,
      keptRuns: keeping.kept, unkeptRuns: keeping.unkept.isEmpty ? nil : keeping.unkept,
      events: events.copied, unkeptEvents: events.unkept)
  }

  /// What `remove` did with a worktree's `.harness/events/`.
  private struct KeptEvents {
    var copied: WorktreeReport.CopiedEvents?
    var unkept: WorktreeReport.UnkeptEvents?
    var message = ""
  }

  /// Copies the worktree's event store into the main checkout's imports, so its judge audit log
  /// and telemetry outlive it. A copy that fails is named; removal still goes ahead, as for runs.
  private static func copyEvents(of names: TaskWorktree) -> KeptEvents {
    let copyUp = EventCopyUp(
      source: URL(filePath: names.path, directoryHint: .isDirectory),
      destination: URL(filePath: names.mainCheckout, directoryHint: .isDirectory))
    let outcome: EventCopyUpOutcome
    do throws(EventCopyUpError) {
      outcome = try copyUp.run()
    } catch {
      let reason = "\(error)"
      // The judge's audit trail must outlive the worktree, so its events move whole instead.
      let common = URL(filePath: names.mainCheckout, directoryHint: .isDirectory)
        .appending(path: ".git", directoryHint: .isDirectory)
      do throws(EventCopyUpError) {
        let moved = try copyUp.moveAside(commonDirectory: common)
        return KeptEvents(
          unkept: .init(copyError: reason, movedTo: moved, moveError: nil),
          message: "; couldn't copy its events (\(reason))"
            + (moved.map { ", moved them to \($0)" } ?? ""))
      } catch {
        return KeptEvents(
          unkept: .init(copyError: reason, movedTo: nil, moveError: "\(error)"),
          message: "; couldn't copy its events (\(reason)) or move them aside (\(error)): "
            + "its events were lost with the worktree")
      }
    }
    switch outcome {
    case .nothing:
      return KeptEvents()
    case .copied(let storeID, let bytes):
      let path = "\(EventCopyUp.importedDirectory)/\(storeID)"
      return KeptEvents(
        copied: .init(storeID: storeID, path: path, bytes: bytes, copied: true),
        message: "; copied its events (\(bytes) bytes) to \(path)")
    case .kept(let storeID, let bytes):
      let path = "\(EventCopyUp.importedDirectory)/\(storeID)"
      return KeptEvents(
        copied: .init(storeID: storeID, path: path, bytes: bytes, copied: false),
        message: "; kept the earlier copy of its events in \(path)")
    }
  }

  /// What `remove` copied out of a worktree's `.harness/runs/` before deleting it.
  private struct KeptRuns {
    var kept: [String] = []
    var unkept: [WorktreeReport.UnkeptRun] = []
    var message = ""
  }

  /// Copies the worktree's gate reports into the main checkout, so a task gate's evidence
  /// outlives the worktree. A run it can't copy is named; removal still goes ahead, since the
  /// branch is merged and a report is diagnostics, not work.
  private static func keepRuns(of names: TaskWorktree) -> KeptRuns {
    let main = RunStore(
      worktreeRoot: URL(filePath: names.mainCheckout, directoryHint: .isDirectory))
    let into = main.worktreeRoot.appending(path: RunLayout.runsDirectory).path
    let outcome: RunKeepOutcome
    do throws(RunStoreError) {
      outcome = try RunStore(worktreeRoot: URL(filePath: names.path, directoryHint: .isDirectory))
        .keepRuns(in: main)
    } catch {
      return KeptRuns(message: "; kept no gate reports, listing them failed: \(error)")
    }
    var result = KeptRuns(
      kept: outcome.kept,
      unkept: outcome.unkept.map { .init(runId: $0.runID, reason: $0.reason) })
    if !outcome.kept.isEmpty {
      result.message += "; kept \(outcome.kept.count) gate report(s) in \(into)"
    }
    if !outcome.unkept.isEmpty {
      result.message +=
        "; couldn't keep "
        + outcome.unkept.map { "\($0.runID) (\($0.reason))" }.joined(separator: ", ")
    }
    return result
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

  /// Sets this task's `branch` and nothing else, under the ledger's lock.
  func recordBranch() async -> Result<Void, Refusal> {
    if let refusal = checkHolder() { return .failure(refusal) }
    do throws(LedgerWriterError) {
      try await LedgerWriter(plan: store.plan).update(task: task, .branch(names.branch))
    } catch {
      switch error {
      case .ledger(let read):
        return .failure(Refusal(report: report.blocked("reading the ledger: \(read)")))
      case .unknownTask:
        return .failure(
          Refusal(report: report.refused("task `\(task)` isn't in plan `\(slug)`'s ledger")))
      case .refusedTransition, .lock, .io:
        return .failure(
          Refusal(report: report.blocked("writing \(store.plan.ledgerFile): \(error)")))
      }
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
    abstract: "Remove a merged task's worktree and branch, or with --fix its fix worktree.",
    discussion:
      "Before removing, copies each gate run under the worktree's .harness/runs/ into the main "
      + "checkout's, and its .harness/events/ to the main checkout's "
      + ".harness/events/imported/<storeID>/; when that copy fails, moves them to "
      + ".harness/events/unkept/<storeID>/ (or the git common dir's "
      + "swift-harness/unkept-events/<storeID>/), naming any it couldn't keep. Exits 0 when removed; 1 when this session doesn't hold the plan's lock, the task isn't in "
      + "the ledger, or its branch is missing or not merged into main; 2 for a missing flag or a "
      + "failed git step, such as a worktree with uncommitted changes.")

  @Argument(help: "The plan's slug.")
  var plan: String

  @Argument(help: "The task's id.")
  var task: String

  @Flag(
    help: ArgumentHelp(
      "Remove the fix worktree <repo>-<plan>-fix-<task> and branch <plan>/fix-<task> instead, "
        + "once build merge --fix has merged it."))
  var fix = false

  @Option(help: "The session id holding the plan's lock (from the SessionStart context).")
  var session: String?

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = FileManager.default.currentDirectoryPath
    let runner = LiveProcessRunner()
    let report = await WorktreeRun.remove(
      slug: plan, task: task, fix: fix, session: session,
      git: LiveGit(runner: runner, repositoryRoot: root),
      workspace: LiveGitWorkspace(runner: runner, repositoryRoot: root))
    Console.write(WorktreeRun.render(report, format: output.format))
    if report.verdict != .green { throw ExitCode(report.verdict.exitCode) }
  }
}

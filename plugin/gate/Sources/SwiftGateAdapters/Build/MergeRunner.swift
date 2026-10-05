import Foundation
import SwiftGateDomain

/// What `git merge` did to a checkout.
public enum MergeOutcome: Sendable, Equatable {
  /// A merge commit was made; `commit` is the checkout's new `HEAD`.
  case merged(commit: String)
  /// The merge stopped on conflicts and left them in the checkout, sorted.
  case conflicted(files: [String])
}

/// The git steps `build merge` takes inside one checkout: reading its branch, cleanliness and
/// commits, and merging, aborting and resetting. Kept apart from ``GitWorkspace``, which never
/// touches a checkout's working tree. `checkout` is an absolute path.
public protocol MergeRunner: Sendable {
  /// The checked-out branch's short name, or `nil` on a detached `HEAD`.
  func currentBranch(in checkout: String) async throws(GitWorkspaceError) -> String?

  /// Tracked paths with staged, unstaged or conflicted changes. Untracked files don't count: a
  /// merge refuses on its own to overwrite one.
  func dirtyPaths(in checkout: String) async throws(GitWorkspaceError) -> [String]

  /// The commit `ref` names.
  func commit(of ref: String, in checkout: String) async throws(GitWorkspaceError) -> String

  /// The subject line of the commit `ref` names.
  func subject(of ref: String, in checkout: String) async throws(GitWorkspaceError) -> String

  /// `git merge --no-ff -m <message> <branch>` into the checked-out branch.
  /// - Throws: when the merge fails for any reason other than conflicts.
  func merge(_ branch: String, message: String, in checkout: String)
    async throws(GitWorkspaceError) -> MergeOutcome

  /// `git merge --abort`.
  func abortMerge(in checkout: String) async throws(GitWorkspaceError)

  /// `git reset --hard <commit>`.
  func resetHard(to commit: String, in checkout: String) async throws(GitWorkspaceError)
}

/// ``MergeRunner`` over `git`.
public struct LiveMergeRunner: MergeRunner {
  private let runner: any ProcessRunner
  private let timeout: Duration

  public init(runner: any ProcessRunner, timeout: Duration = .seconds(600)) {
    self.runner = runner
    self.timeout = timeout
  }

  public func currentBranch(in checkout: String) async throws(GitWorkspaceError) -> String? {
    let arguments = ["symbolic-ref", "--quiet", "--short", "HEAD"]
    let output = try await git(arguments, in: checkout)
    switch output.status {
    case .exited(0): return output.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
    case .exited(1): return nil
    default:
      throw .git(
        .commandFailed(arguments: arguments, status: output.status, stderr: output.stderr.text))
    }
  }

  public func dirtyPaths(in checkout: String) async throws(GitWorkspaceError) -> [String] {
    let output = try await succeed(
      ["status", "--porcelain=v1", "--untracked-files=no"], in: checkout)
    return output.split(separator: "\n").map { String($0.dropFirst(3)) }.sorted()
  }

  public func commit(of ref: String, in checkout: String) async throws(GitWorkspaceError)
    -> String
  {
    try Self.checkRef(ref)
    return try await succeed(["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"], in: checkout)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public func subject(of ref: String, in checkout: String) async throws(GitWorkspaceError)
    -> String
  {
    try Self.checkRef(ref)
    return try await succeed(["log", "-1", "--format=%s", ref, "--"], in: checkout)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public func merge(_ branch: String, message: String, in checkout: String)
    async throws(GitWorkspaceError) -> MergeOutcome
  {
    try Self.checkRef(branch)
    let arguments = ["merge", "--no-ff", "--no-edit", "-m", message, branch]
    let output = try await git(arguments, in: checkout)
    if output.status.isSuccess {
      return .merged(commit: try await commit(of: "HEAD", in: checkout))
    }
    let conflicted = try await succeed(
      ["diff", "--name-only", "--diff-filter=U", "-z"], in: checkout
    ).split(separator: "\0").map(String.init).sorted()
    guard !conflicted.isEmpty else {
      throw .git(
        .commandFailed(
          arguments: arguments, status: output.status,
          stderr: output.stderr.text + output.stdout.text))
    }
    return .conflicted(files: conflicted)
  }

  public func abortMerge(in checkout: String) async throws(GitWorkspaceError) {
    _ = try await succeed(["merge", "--abort"], in: checkout)
  }

  public func resetHard(to commit: String, in checkout: String) async throws(GitWorkspaceError) {
    try Self.checkRef(commit)
    _ = try await succeed(["reset", "--quiet", "--hard", commit], in: checkout)
  }

  private static func checkRef(_ ref: String) throws(GitWorkspaceError) {
    if ref.isEmpty || ref.hasPrefix("-") { throw .git(.invalidRef(ref)) }
  }

  private func succeed(_ arguments: [String], in checkout: String)
    async throws(GitWorkspaceError) -> String
  {
    let output = try await git(arguments, in: checkout)
    guard output.status.isSuccess else {
      throw .git(
        .commandFailed(arguments: arguments, status: output.status, stderr: output.stderr.text))
    }
    return output.stdout.text
  }

  private func git(_ arguments: [String], in checkout: String)
    async throws(GitWorkspaceError) -> ProcessOutput
  {
    do {
      return try await runner.run(
        ProcessInvocation(
          executable: "git", arguments: arguments, workingDirectory: checkout, timeout: timeout))
    } catch {
      throw .git(.process(error))
    }
  }
}

/// What `build merge` or `build merge --undo` did. Optional keys are omitted from JSON, never
/// `null`.
public struct BuildMergeReport: Sendable, Equatable, Encodable {
  public enum Status: String, Sendable, Encodable {
    case merged
    case undone
    /// The merge conflicted: `main` is untouched and the fix worktree holds the conflicts.
    case conflicted
    /// `main` isn't where a merge may happen, or there's nothing to undo; nothing changed.
    case refused
    /// The lock is free or another session holds it; nothing changed.
    case notHeld = "not-held"
    case blocked
  }

  /// Why a merge or undo didn't happen, for a `refused`, `conflicted` or `not-held` report. Closed,
  /// so a caller matches on it rather than on the message's wording.
  public enum Reason: String, Sendable, Equatable, Encodable, CaseIterable {
    /// `main` isn't where the run's newest merge or undo event left it.
    case mainMoved = "main-moved"
    /// The main checkout has uncommitted changes to tracked files.
    case dirtyCheckout = "dirty-checkout"
    /// The main checkout is on another branch or a detached `HEAD`.
    case notOnMain = "not-on-main"
    /// The caller doesn't hold the plan's lock.
    case notHeld = "not-held"
    /// The branch conflicts with `main`.
    case conflicted
    /// The run's newest merge isn't this task's, is already undone, or there is none.
    case undoRefused = "undo-refused"
    /// The branch to merge doesn't exist.
    case branchMissing = "branch-missing"
    /// The branch is already merged into `main`.
    case alreadyMerged = "already-merged"
    /// No `build check-return` of this return is recorded in the build run.
    case returnUnchecked = "return-unchecked"
    /// The newest `build check-return` of this return wasn't GREEN.
    case returnNotGreen = "return-not-green"
    /// The newest GREEN `build check-return` covered another commit than the branch tip.
    case returnStale = "return-stale"
  }

  /// Whether `main` was checked against the run's last merge.
  public enum MainCheck: String, Sendable, Encodable {
    /// `main` was where the run's newest merge or undo event left it.
    case atLastMerge = "at-last-merge"
    /// The run has no merge event yet, so there was no recorded commit to compare `main` with.
    case noMergeYet = "no-merge-yet"
  }

  public let command: String
  public let plan: String
  public let task: String
  public let status: Status
  public let reason: Reason?
  public let verdict: Verdict
  public let holder: String?
  public let runId: String?
  public let branch: String?
  public let mainCheckout: String?
  public let mainCheck: MainCheck?
  public let preCommit: String?
  public let postCommit: String?
  public let fixWorktree: String?
  public let fixBranch: String?
  public let conflictedFiles: [String]?
  public let message: String

  public init(
    command: String, plan: String, task: String, status: Status, reason: Reason? = nil,
    verdict: Verdict, holder: String? = nil, runId: String? = nil, branch: String? = nil,
    mainCheckout: String? = nil, mainCheck: MainCheck? = nil, preCommit: String? = nil,
    postCommit: String? = nil, fixWorktree: String? = nil, fixBranch: String? = nil,
    conflictedFiles: [String]? = nil, message: String
  ) {
    self.command = command
    self.plan = plan
    self.task = task
    self.status = status
    self.reason = reason
    self.verdict = verdict
    self.holder = holder
    self.runId = runId
    self.branch = branch
    self.mainCheckout = mainCheckout
    self.mainCheck = mainCheck
    self.preCommit = preCommit
    self.postCommit = postCommit
    self.fixWorktree = fixWorktree
    self.fixBranch = fixBranch
    self.conflictedFiles = conflictedFiles
    self.message = message
  }
}

/// `build merge` after the lock-holder check (spec §8.2, §8.3): merges a task branch onto `main`
/// in the main checkout only when `main` is where the run's last merge left it, and on a conflict
/// or an undo cuts the fix worktree `<repo>-<plan>-fix-<task>` on `<plan>/fix-<task>`.
public struct BuildMerge: Sendable {
  public static let mergeCommand = "build merge"
  public static let undoCommand = "build merge --undo"

  let plan: String
  let task: String
  let fix: Bool
  let git: any Git
  let workspace: any GitWorkspace
  let merger: any MergeRunner
  let clock: any BuildClock
  /// Which ``TaskWorktree`` layout names the checkout and branch merges land in.
  let profile: RepositoryProfile

  public init(
    plan: String, task: String, fix: Bool = false, git: any Git, workspace: any GitWorkspace,
    merger: any MergeRunner, clock: any BuildClock, profile: RepositoryProfile = .owned
  ) {
    self.profile = profile
    self.plan = plan
    self.task = task
    self.fix = fix
    self.git = git
    self.workspace = workspace
    self.merger = merger
    self.clock = clock
  }

  private struct Stop: Error {
    let report: BuildMergeReport
  }

  /// Everything both verbs resolve before touching `main`.
  private struct Context {
    let run: BuildRunStore
    let names: TaskWorktree
    let fix: TaskWorktree
    /// The branch this call merges: the task's, or with `--fix` the fixer's.
    let branch: String
  }

  public func merge() async -> BuildMergeReport {
    let command = Self.mergeCommand
    do throws(Stop) {
      let context = try await resolve(command)
      let main = context.names.mainCheckout
      let last: String?
      do throws(BuildRunStoreError) {
        last = try context.run.lastMergePostCommit()
      } catch {
        throw stop(command, context, .blocked, "reading \(context.run.layout.eventsFile): \(error)")
      }
      let pre = try await checkMain(command, context, expected: last)
      let mainCheck: BuildMergeReport.MainCheck = last == nil ? .noMergeYet : .atLastMerge
      let branch = context.branch
      let merged = try await step(command, context, "reading \(branch)") {
        () async throws(GitWorkspaceError) in
        try await workspace.isMerged(branch, into: context.names.baseBranch)
      }
      if merged {
        throw stop(
          command, context, .refused,
          "\(branch) is already merged into \(context.names.baseBranch)",
          reason: .alreadyMerged)
      }
      try await checkReturn(command, context)
      let outcome = try await step(command, context, "merging in \(main)") {
        () async throws(GitWorkspaceError) in
        let subject = try await merger.subject(of: "refs/heads/\(branch)", in: main)
        return try await merger.merge(branch, message: "Merge: \(subject)", in: main)
      }
      switch outcome {
      case .merged(let post):
        do throws(BuildRunStoreError) {
          try await context.run.append(
            .merge(.init(task: task, preCommit: pre, postCommit: post, at: clock.now())))
        } catch {
          throw stop(
            command, context, .blocked,
            "merged \(branch) into \(context.names.baseBranch) (\(pre) → \(post)) but "
              + "couldn't record the merge event: \(error). `main` is merged; record or reset it "
              + "by hand before the next merge.", pre: pre, post: post)
        }
        return report(
          command, context, .merged, .green, mainCheck: mainCheck, pre: pre, post: post,
          message: "merged \(branch) into \(context.names.baseBranch): \(pre) → \(post)"
            + (last == nil ? "; no earlier merge event, so main wasn't compared with one" : ""))
      case .conflicted(let files):
        try await abort(command, context, pre: pre)
        if fix {
          return report(
            command, context, .conflicted, .red, reason: .conflicted, mainCheck: mainCheck,
            pre: pre, conflicted: files,
            message: "\(branch) conflicts with \(context.names.baseBranch) in "
              + files.joined(separator: ", ") + "; main is untouched at \(pre). Resolve it in "
              + "\(context.fix.path) and merge again.")
        }
        let (fixFiles, detail) = try await cutFix(command, context)
        return report(
          command, context, .conflicted, .red, reason: .conflicted, mainCheck: mainCheck,
          pre: pre, conflicted: fixFiles.isEmpty ? files : fixFiles,
          message: "\(branch) conflicts with \(context.names.baseBranch) in "
            + files.joined(separator: ", ") + "; main is untouched at \(pre). \(detail)")
      }
    } catch {
      return error.report
    }
  }

  public func undo() async -> BuildMergeReport {
    let command = Self.undoCommand
    do throws(Stop) {
      let context = try await resolve(command)
      let log: BuildEventLog
      do throws(BuildRunStoreError) {
        log = try context.run.events()
      } catch {
        throw stop(command, context, .blocked, "reading \(context.run.layout.eventsFile): \(error)")
      }
      guard log.damage.isEmpty else {
        throw stop(
          command, context, .blocked,
          "\(context.run.layout.eventsFile) is damaged (\(log.damage)); the lost line could be a "
            + "later merge, so there's no trustworthy merge to undo")
      }
      let newest = log.events.last {
        switch $0 {
        case .merge, .undo: true
        case .transition, .gate, .returnCheck, .finish: false
        }
      }
      let lastMerge: BuildEvent.Merge
      switch newest {
      case .merge(let merge) where merge.task == task:
        lastMerge = merge
      case .merge(let merge):
        throw stop(
          command, context, .refused,
          "the run's newest merge is task `\(merge.task)`, not `\(task)`; undoing `\(task)` "
            + "would also drop it", reason: .undoRefused)
      case .undo(let undo):
        throw stop(
          command, context, .refused,
          "the run's newest merge, task `\(undo.task)`'s, is already undone",
          reason: .undoRefused)
      case .transition, .gate, .returnCheck, .finish, nil:
        throw stop(
          command, context, .refused, "build run \(context.run.runID) has no merge to undo",
          reason: .undoRefused)
      }
      _ = try await checkMain(command, context, expected: lastMerge.postCommit)
      try await checkFixIsFree(command, context)
      let main = context.names.mainCheckout
      try await step(command, context, "resetting \(main)") {
        () async throws(GitWorkspaceError) in
        try await merger.resetHard(to: lastMerge.preCommit, in: main)
      }
      do throws(BuildRunStoreError) {
        try await context.run.append(
          .undo(
            .init(
              task: task, fromCommit: lastMerge.postCommit, toCommit: lastMerge.preCommit,
              at: clock.now())))
      } catch {
        throw stop(
          command, context, .blocked,
          "reset \(context.names.baseBranch) from \(lastMerge.postCommit) to \(lastMerge.preCommit) but "
            + "couldn't record the undo event: \(error). Every later merge will be refused as "
            + "`main` moved until the log says where main is.", pre: lastMerge.preCommit,
          post: lastMerge.postCommit)
      }
      let (files, detail) = try await cutFix(command, context)
      return report(
        command, context, .undone, .green, mainCheck: .atLastMerge, pre: lastMerge.preCommit,
        post: lastMerge.postCommit, conflicted: files.isEmpty ? nil : files,
        message: "reset \(context.names.baseBranch) from \(lastMerge.postCommit) to "
          + "\(lastMerge.preCommit). \(detail)")
    } catch {
      return error.report
    }
  }

  private func resolve(_ command: String) async throws(Stop) -> Context {
    let common: String
    do {
      common = try await git.commonDirectory()
    } catch {
      throw bare(command, .blocked, "can't find the git common dir: \(error)")
    }
    let names: TaskWorktree
    let fix: TaskWorktree
    do throws(GitWorkspaceError) {
      names = try TaskWorktree(commonDirectory: common, plan: plan, task: task, profile: profile)
      fix = try TaskWorktree(
        commonDirectory: common, plan: plan, task: "fix-\(task)", profile: profile)
    } catch {
      throw bare(command, .blocked, "\(error)")
    }
    let latest: BuildRunStore?
    do throws(BuildRunStoreError) {
      latest = try await BuildRunStore.latest(plan: plan, git: git)
    } catch {
      throw bare(command, .blocked, "finding plan `\(plan)`'s build run: \(error)")
    }
    guard let run = latest else {
      throw bare(
        command, .blocked, "plan `\(plan)` has no build run; run `swiftgate build start` first")
    }
    let branch = self.fix && command == Self.mergeCommand ? fix.branch : names.branch
    let context = Context(run: run, names: names, fix: fix, branch: branch)
    let exists = try await step(command, context, "reading \(branch)") {
      () async throws(GitWorkspaceError) in
      try await workspace.branchExists(branch)
    }
    guard exists else {
      throw stop(
        command, context, .refused, "branch \(branch) doesn't exist", reason: .branchMissing)
    }
    return context
  }

  /// Refuses unless the main checkout is on a clean `main` at `expected` (when there is one).
  /// - Returns: `main`'s commit.
  private func checkMain(_ command: String, _ context: Context, expected: String?)
    async throws(Stop) -> String
  {
    let main = context.names.mainCheckout
    let base = context.names.baseBranch
    let (branch, dirty, head) = try await step(command, context, "reading \(main)") {
      () async throws(GitWorkspaceError) in
      (
        try await merger.currentBranch(in: main), try await merger.dirtyPaths(in: main),
        try await merger.commit(of: "refs/heads/\(base)", in: main)
      )
    }
    guard branch == base else {
      throw stop(
        command, context, .refused,
        "\(main) is on \(branch ?? "a detached HEAD"), not \(base); switch it back first",
        reason: .notOnMain)
    }
    guard dirty.isEmpty else {
      throw stop(
        command, context, .refused,
        "\(main) has uncommitted changes in \(dirty.joined(separator: ", ")); commit or stash "
          + "them first", reason: .dirtyCheckout)
    }
    if let expected, head != expected {
      throw stop(
        command, context, .refused,
        "\(base) moved since the run's last merge: it is at \(head), the last merge left it at "
          + "\(expected). Another session may have merged; find out who before merging.",
        reason: .mainMoved)
    }
    return head
  }

  /// Refuses unless the build run's newest `build check-return` of this return, the task's or
  /// with `--fix` its fixer's, is GREEN for the commit the branch is at now: a check of the
  /// other return, of an earlier tip, or that found anything vouches for nothing this merge takes.
  private func checkReturn(_ command: String, _ context: Context) async throws(Stop) {
    let log: BuildEventLog
    do throws(BuildRunStoreError) {
      log = try context.run.events()
    } catch {
      throw stop(command, context, .blocked, "reading \(context.run.layout.eventsFile): \(error)")
    }
    let whose = fix ? "the fixer's return for task `\(task)`" : "task `\(task)`'s return"
    let flag = fix ? " --fix" : ""
    let branch = context.branch
    guard log.damage.isEmpty else {
      throw stop(
        command, context, .blocked,
        "\(context.run.layout.eventsFile) is damaged (\(log.damage)); the lost line could be "
          + "\(whose)'s newest check, so there's no trustworthy check to merge on")
    }
    guard let check = log.latestReturnCheck(task: task, fix: fix) else {
      throw stop(
        command, context, .refused,
        "build-merge.\(BuildMergeReport.Reason.returnUnchecked.rawValue): build run "
          + "\(context.run.runID) records no `build check-return\(flag)` of \(whose); check it, "
          + "and merge only when it exits 0", reason: .returnUnchecked)
    }
    guard check.verdict == .green else {
      let rules =
        check.rules.isEmpty ? "" : " (\(check.rules.map(\.rawValue).joined(separator: ", ")))"
      throw stop(
        command, context, .refused,
        "build-merge.\(BuildMergeReport.Reason.returnNotGreen.rawValue): the newest `build "
          + "check-return\(flag)` of \(whose), check \(check.checkID), is "
          + "\(check.verdict.rawValue)\(rules); merge only a return that checks GREEN",
        reason: .returnNotGreen)
    }
    let main = context.names.mainCheckout
    let tip = try await step(command, context, "reading \(branch)") {
      () async throws(GitWorkspaceError) in
      try await merger.commit(of: "refs/heads/\(branch)", in: main)
    }
    guard check.commit == tip else {
      throw stop(
        command, context, .refused,
        "build-merge.\(BuildMergeReport.Reason.returnStale.rawValue): check \(check.checkID) of "
          + "\(whose) was GREEN for commit \(check.commit ?? "none"), but \(branch) is at \(tip); "
          + "check the return that names \(tip) as its last commit before merging",
        reason: .returnStale)
    }
  }

  /// Aborts a conflicted merge in the main checkout and proves `main` is back where it was.
  private func abort(_ command: String, _ context: Context, pre: String) async throws(Stop) {
    let main = context.names.mainCheckout
    let (head, dirty) = try await step(
      command, context, "aborting the conflicted merge in \(main) (fix it by hand)", pre: pre
    ) { () async throws(GitWorkspaceError) in
      try await merger.abortMerge(in: main)
      return (try await merger.commit(of: "HEAD", in: main), try await merger.dirtyPaths(in: main))
    }
    guard head == pre, dirty.isEmpty else {
      throw stop(
        command, context, .blocked,
        "aborting the conflicted merge left \(main) at \(head) with changes in "
          + "\(dirty.joined(separator: ", ")), not clean at \(pre); fix it by hand", pre: pre)
    }
  }

  private func checkFixIsFree(_ command: String, _ context: Context) async throws(Stop) {
    if FileManager.default.fileExists(atPath: context.fix.path) {
      throw stop(
        command, context, .blocked,
        "the fix worktree \(context.fix.path) already exists; remove it first")
    }
    let exists = try await step(command, context, "reading \(context.fix.branch)") {
      () async throws(GitWorkspaceError) in
      try await workspace.branchExists(context.fix.branch)
    }
    if exists {
      throw stop(
        command, context, .blocked,
        "the fix branch \(context.fix.branch) already exists; delete it first")
    }
  }

  /// Cuts the fix worktree from `main` and merges the task branch into it, leaving any conflict.
  /// - Returns: the fix worktree's conflicted files, and a sentence for the message.
  private func cutFix(_ command: String, _ context: Context) async throws(Stop)
    -> ([String], String)
  {
    try await checkFixIsFree(command, context)
    let fix = context.fix
    let branch = context.names.branch
    let outcome = try await step(command, context, "cutting the fix worktree \(fix.path)") {
      () async throws(GitWorkspaceError) in
      try await workspace.addWorktree(
        at: fix.path, branch: fix.branch, from: context.names.baseBranch)
      let subject = try await merger.subject(of: "refs/heads/\(branch)", in: fix.path)
      return try await merger.merge(branch, message: "Merge: \(subject)", in: fix.path)
    }
    let cut = "Fix worktree \(fix.path) on \(fix.branch) has \(branch) merged in"
    switch outcome {
    case .merged: return ([], cut + ".")
    case .conflicted(let files):
      return (files, cut + ", conflicted in \(files.joined(separator: ", ")).")
    }
  }

  /// Runs one or more git steps, turning a git failure into a blocked report.
  private func step<T>(
    _ command: String, _ context: Context, _ what: String, pre: String? = nil,
    _ body: () async throws(GitWorkspaceError) -> T
  ) async throws(Stop) -> T {
    do {
      return try await body()
    } catch {
      throw stop(command, context, .blocked, "\(what): \(error)", pre: pre)
    }
  }

  private func stop(
    _ command: String, _ context: Context, _ status: BuildMergeReport.Status, _ message: String,
    reason: BuildMergeReport.Reason? = nil, pre: String? = nil, post: String? = nil
  ) -> Stop {
    Stop(
      report: report(
        command, context, status, status == .blocked ? .blocked : .red, reason: reason, pre: pre,
        post: post, message: message))
  }

  private func bare(_ command: String, _ status: BuildMergeReport.Status, _ message: String)
    -> Stop
  {
    Stop(
      report: BuildMergeReport(
        command: command, plan: plan, task: task, status: status,
        verdict: status == .blocked ? .blocked : .red, message: message))
  }

  private func report(
    _ command: String, _ context: Context, _ status: BuildMergeReport.Status, _ verdict: Verdict,
    reason: BuildMergeReport.Reason? = nil, mainCheck: BuildMergeReport.MainCheck? = nil,
    pre: String? = nil, post: String? = nil,
    conflicted: [String]? = nil, message: String
  ) -> BuildMergeReport {
    let cut = status == .conflicted || status == .undone
    return BuildMergeReport(
      command: command, plan: plan, task: task, status: status, reason: reason, verdict: verdict,
      runId: context.run.runID, branch: context.branch,
      mainCheckout: context.names.mainCheckout, mainCheck: mainCheck, preCommit: pre,
      postCommit: post, fixWorktree: cut ? context.fix.path : nil,
      fixBranch: cut ? context.fix.branch : nil, conflictedFiles: conflicted, message: message)
  }
}

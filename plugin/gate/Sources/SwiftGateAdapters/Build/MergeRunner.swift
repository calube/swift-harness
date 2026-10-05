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
    /// The newest check is of a `review-blocked` return, and no halt of the task since then was
    /// answered `merge`.
    case reviewBlockedUnanswered = "review-blocked-unanswered"
    /// A validation row runs after this task with every other task it waits on merged, and no
    /// `qa run --before-merge` of the branch at its tip on `main`'s commit is GREEN or conflicted.
    case flowsUnchecked = "flows-unchecked"
    /// The newest `qa run --before-merge` of the branch at its tip on `main`'s commit is RED.
    case flowsRed = "flows-red"
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
  /// The merge gate run `--undo` recorded in the build run's log for the commit it undid; `nil`
  /// when the log already held it or no `check` run started at that commit.
  public let gateRunId: String?
  /// The scratch trees an undo pruned, left by gates that ended without removing them.
  public var prunedScratchTrees: [String]?
  /// The branches `--undo` kept the work it took off `main` on, or an earlier fix branch it set
  /// aside before cutting the new one, as `<plan>/fix-<task>-<n>`; `nil` when it kept none.
  public let keptBranches: [String]?
  public let message: String

  public init(
    command: String, plan: String, task: String, status: Status, reason: Reason? = nil,
    verdict: Verdict, holder: String? = nil, runId: String? = nil, branch: String? = nil,
    mainCheckout: String? = nil, mainCheck: MainCheck? = nil, preCommit: String? = nil,
    postCommit: String? = nil, fixWorktree: String? = nil, fixBranch: String? = nil,
    conflictedFiles: [String]? = nil, gateRunId: String? = nil, keptBranches: [String]? = nil,
    message: String
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
    self.gateRunId = gateRunId
    self.keptBranches = keptBranches
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
  /// Prunes the scratch trees of gates that ended unfinished once an undo lands; `nil` leaves
  /// them.
  let leftovers: (any RunLeftovers)?
  /// The store a `review-blocked` return's answered halt is read from; `nil` when telemetry is
  /// off, so no halt is ever recorded and none is required.
  let halts: BuildHaltLog?

  public init(
    plan: String, task: String, fix: Bool = false, git: any Git, workspace: any GitWorkspace,
    merger: any MergeRunner, clock: any BuildClock, profile: RepositoryProfile = .owned,
    leftovers: (any RunLeftovers)? = nil, halts: BuildHaltLog? = nil
  ) {
    self.profile = profile
    self.leftovers = leftovers
    self.halts = halts
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
    /// The git common dir, holding the plan's state.
    let common: String
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
      try await checkFlows(command, context, main: pre)
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
      let removed = try await removeFixWorktree(command, context)
      let main = context.names.mainCheckout
      let gate = await recordMergeGate(context, at: lastMerge.postCommit)
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
      let kept = try await keepUndoneWork(command, context, undone: lastMerge)
      let (files, detail) = try await cutFix(command, context)
      // The merge gate that sent this undo may have died inside its prove, leaving a scratch
      // tree registered.
      let sweep = await leftovers?.pruneScratchTrees()
      let pruned = sweep.map { sweep in
        (sweep.removed.isEmpty ? "" : " Pruned \(sweep.removed.count) scratch tree(s).")
          + sweep.failures.map { " A scratch tree wasn't pruned: \($0)." }.joined()
      }
      let keptNote =
        kept.isEmpty
        ? ""
        : " Kept the work it took off \(context.names.baseBranch) on "
          + "\(kept.joined(separator: ", ")); merge it into the fix worktree to build on it."
      var undone = report(
        command, context, .undone, .green, mainCheck: .atLastMerge, pre: lastMerge.preCommit,
        post: lastMerge.postCommit, conflicted: files.isEmpty ? nil : files,
        gateRunId: gate.runID, keptBranches: kept.isEmpty ? nil : kept,
        message: "reset \(context.names.baseBranch) from \(lastMerge.postCommit) to "
          + "\(lastMerge.preCommit).\(gate.note)\(removed)\(keptNote) \(detail)\(pruned ?? "")")
      undone.prunedScratchTrees = sweep?.removed
      return undone
    } catch {
      return error.report
    }
  }

  /// Appends the newest `check --tier` run that started on the main checkout at `commit`, the
  /// merge gate that sent this undo, as the task's merge gate, unless the log already holds it.
  /// A gate that can't be found or recorded never stops the undo; the note says why.
  private func recordMergeGate(_ context: Context, at commit: String) async
    -> (runID: String?, note: String)
  {
    let runs = RunStore(
      worktreeRoot: URL(filePath: context.names.mainCheckout, directoryHint: .isDirectory))
    let records: [RunHistoryRecord]
    do throws(RunStoreError) {
      records = try runs.readHistory().records
    } catch {
      return (nil, " Its merge gate wasn't recorded: reading the run history: \(error).")
    }
    guard
      let record = records.last(where: {
        $0.headCommit == commit && TaskReturnEvidence.GateRun.tier(ofCommand: $0.command) != nil
      }),
      let tier = TaskReturnEvidence.GateRun.tier(ofCommand: record.command)
    else { return (nil, "") }
    let runID = record.runID
    do throws(BuildRunStoreError) {
      let appended = try await context.run.append(
        .gate(
          .init(
            stage: .merge(task: task), tier: tier, verdict: record.verdict, runID: runID,
            at: clock.now()))
      ) { held in
        if case .gate(let gate) = held { return gate.runID == runID }
        return false
      }
      guard appended else { return (nil, "") }
    } catch {
      return (nil, " Its merge gate \(record.runID) wasn't recorded: \(error).")
    }
    return (
      record.runID,
      " Recorded its merge gate \(record.runID), \(tier.rawValue) \(record.verdict.rawValue)."
    )
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
    let context = Context(run: run, names: names, fix: fix, branch: branch, common: common)
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

  /// Refuses while a validation row runs after this task with every other task it waits on
  /// merged, unless the newest `qa run --after <task> --before-merge` of the branch at its tip on
  /// `main`'s commit is GREEN, or conflicted, which the merge then shows. A RED one cuts the fix
  /// worktree, as a conflict does, unless this merges the fixer's branch, whose worktree exists.
  /// A plan with no table, or one whose state doesn't read, needs no run here: `qa run` itself
  /// reports that table.
  private func checkFlows(_ command: String, _ context: Context, main: String)
    async throws(Stop)
  {
    let readiness: QAMergeReadiness
    let tip: String
    do {
      let plan = try PlanStateLayout(commonDirectory: context.common).plan(self.plan)
      guard
        let data = FileManager.default.contents(
          atPath: plan.directory + "/" + ValidationTable.fileName)
      else { return }
      let table = try ValidationTableJSON.decode(data)
      let progress = try PlanStateStore(plan: plan).ledgerProgress()
      let log = try context.run.events()
      tip = try await merger.commit(
        of: "refs/heads/\(context.branch)", in: context.names.mainCheckout)
      readiness = QAMergeReadiness.of(
        table: table, merged: progress.merged(per: log), plan: self.plan, task: task,
        reports: beforeMergeReports(context), branch: context.branch, tip: tip, base: main)
    } catch {
      return
    }
    let run =
      "`swiftgate qa run --plan \(plan) --after \(task) --before-merge\(fix ? " --fix" : "")`"
    switch readiness {
    case .notNeeded, .checked, .conflicts:
      return
    case .unchecked(let rows):
      throw stop(
        command, context, .refused,
        "build-merge.\(BuildMergeReport.Reason.flowsUnchecked.rawValue): validation "
          + "\(rows.count == 1 ? "row" : "rows") \(rows.map(String.init).joined(separator: ", ")) "
          + "\(rows.count == 1 ? "runs" : "run") after `\(task)` with every other task "
          + "\(rows.count == 1 ? "it waits" : "they wait") on merged, and no GREEN \(run) covers "
          + "\(context.branch) at \(tip) on \(context.names.baseBranch) at \(main); run it in "
          + "\(context.names.mainCheckout) and merge once it is GREEN",
        reason: .flowsUnchecked)
    case .red(let runID, let rows):
      let red =
        "build-merge.\(BuildMergeReport.Reason.flowsRed.rawValue): \(run) run \(runID) is RED "
        + "at \(context.branch)'s tip \(tip) on \(context.names.baseBranch) at \(main), in "
        + rows.map { "row \($0.row) (\($0.requirement)) `\($0.check)`: \($0.message)" }
        .joined(separator: "; ") + "; main is untouched."
      if fix {
        throw stop(
          command, context, .refused, red + " Fix it in \(context.fix.path) and run it again.",
          reason: .flowsRed)
      }
      let (_, detail) = try await cutFix(command, context)
      throw Stop(
        report: report(
          command, context, .refused, .red, reason: .flowsRed, pre: main, cut: true,
          message: red + " " + detail))
    }
  }

  /// The plan's `qa run --before-merge` reports in the main checkout's runs, where the build
  /// skill runs them; a report that doesn't decode is passed over.
  private func beforeMergeReports(_ context: Context) -> [QAReport] {
    let runs = RunStore(
      worktreeRoot: URL(filePath: context.names.mainCheckout, directoryHint: .isDirectory)
    ).state.url(RunLayout.runsDirectory, directoryHint: .isDirectory)
    let ids = (try? FileManager.default.contentsOfDirectory(atPath: runs.path)) ?? []
    return ids.filter(RunID.isValid).compactMap { id in
      let file = runs.appending(path: "\(id)/\(QAReport.directory)/\(QAReport.fileName)")
      guard let data = try? Data(contentsOf: file), let report = try? QAReportJSON.decode(data),
        report.plan == plan, report.after == task, report.trialMerge != nil
      else { return nil }
      return report
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

  /// Removes the fix worktree an earlier undo or conflict cut, so this undo can cut a fresh one
  /// from the reset `main`. Its gate reports and events are kept first. A worktree with
  /// uncommitted changes blocks before `main` moves: the fixer's edits would go with it. Its
  /// branch stays until ``keepUndoneWork(_:_:undone:)`` sets it aside.
  /// - Returns: a sentence for the message, empty when there was no fix worktree.
  private func removeFixWorktree(_ command: String, _ context: Context) async throws(Stop)
    -> String
  {
    let fix = context.fix
    guard FileManager.default.fileExists(atPath: fix.path) else { return "" }
    let dirty = try await step(command, context, "reading \(fix.path)") {
      () async throws(GitWorkspaceError) in
      try await merger.dirtyPaths(in: fix.path)
    }
    guard dirty.isEmpty else {
      throw stop(
        command, context, .blocked,
        "the fix worktree \(fix.path) has uncommitted changes in "
          + "\(dirty.joined(separator: ", ")); commit or discard them, then undo again")
    }
    let kept = Self.keepEvidence(of: fix)
    try await step(command, context, "removing the fix worktree \(fix.path)") {
      () async throws(GitWorkspaceError) in
      try await workspace.removeWorktree(at: fix.path, force: false)
    }
    return " Removed the earlier fix worktree \(fix.path)\(kept)."
  }

  /// Copies a worktree's gate reports where the run report reads them, and its own events into
  /// the main checkout's imports. A copy that fails is named and never stops the removal: the
  /// worktree's commits stay on its branch, and its reports are diagnostics.
  private static func keepEvidence(of worktree: TaskWorktree) -> String {
    let root = URL(filePath: worktree.path, directoryHint: .isDirectory)
    let destination = StateRootResolver.keptRuns(
      commonDir: URL(filePath: worktree.commonDirectory, directoryHint: .isDirectory),
      mainCheckout: URL(filePath: worktree.mainCheckout, directoryHint: .isDirectory))
    var note = ""
    do throws(RunStoreError) {
      let outcome = try RunStore(worktreeRoot: root).keepRuns(into: destination)
      if !outcome.kept.isEmpty { note += ", keeping its \(outcome.kept.count) gate report(s)" }
      if !outcome.unkept.isEmpty {
        note += ", losing gate report(s) \(outcome.unkept.map(\.runID).joined(separator: ", "))"
      }
    } catch {
      note += ", keeping no gate report: \(error)"
    }
    let events = EventCopyUp(
      source: root,
      destination: URL(filePath: worktree.mainCheckout, directoryHint: .isDirectory))
    do throws(EventCopyUpError) {
      _ = try events.run()
    } catch {
      note += ", losing its events: \(error)"
    }
    return note
  }

  /// After the reset, keeps every commit the undone merge brought onto a branch. A standing fix
  /// branch that `main` no longer holds moves to the first free `<plan>/fix-<task>-<n>`, and one
  /// it still holds is deleted. Then, when no branch holds the undone merge's second parent, the
  /// tip it merged, as when its fix branch was deleted once merged, that tip gets one too.
  /// - Returns: the branches made, in the order made.
  private func keepUndoneWork(
    _ command: String, _ context: Context, undone: BuildEvent.Merge
  ) async throws(Stop) -> [String] {
    let fix = context.fix.branch
    let base = context.names.baseBranch
    let main = context.names.mainCheckout
    return try await step(
      command, context, "keeping the undone work on a branch", pre: undone.preCommit
    ) { () async throws(GitWorkspaceError) in
      var kept: [String] = []
      func free() async throws(GitWorkspaceError) -> String {
        var n = 1
        while try await workspace.branchExists("\(fix)-\(n)") { n += 1 }
        return "\(fix)-\(n)"
      }
      if try await workspace.branchExists(fix) {
        if try await !workspace.isMerged(fix, into: base) {
          let name = try await free()
          try await workspace.createBranch(
            name, at: try await merger.commit(of: "refs/heads/\(fix)", in: main))
          kept.append(name)
        }
        try await workspace.deleteBranch(fix)
      }
      let tip: String
      do {
        tip = try await merger.commit(of: "\(undone.postCommit)^2", in: main)
      } catch {
        return kept
      }
      if try await workspace.branches(containing: tip).isEmpty {
        let name = try await free()
        try await workspace.createBranch(name, at: tip)
        kept.append(name)
      }
      return kept
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
    conflicted: [String]? = nil, gateRunId: String? = nil, keptBranches: [String]? = nil,
    cut: Bool = false, message: String
  ) -> BuildMergeReport {
    let cut = cut || status == .conflicted || status == .undone
    return BuildMergeReport(
      command: command, plan: plan, task: task, status: status, reason: reason, verdict: verdict,
      runId: context.run.runID, branch: context.branch,
      mainCheckout: context.names.mainCheckout, mainCheck: mainCheck, preCommit: pre,
      postCommit: post, fixWorktree: cut ? context.fix.path : nil,
      fixBranch: cut ? context.fix.branch : nil, conflictedFiles: conflicted,
      gateRunId: gateRunId, keptBranches: keptBranches, message: message)
  }
}

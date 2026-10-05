import Foundation
import SwiftGateDomain

/// Why a worktree or branch mutation, or a warm-build clone, failed. Never evidence about the code.
public enum GitWorkspaceError: Error, Sendable, Equatable, CustomStringConvertible {
  case git(GitError)
  case clone(path: String, detail: String)
  /// A pooled worktree slot couldn't be taken, returned or recorded.
  case pool(path: String, detail: String)

  public var verdict: Verdict { .blocked }

  public var description: String {
    switch self {
    case .git(.commandFailed(let arguments, let status, let stderr)):
      "git \(arguments.joined(separator: " ")) failed (\(status)): "
        + stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    case .git(let error): "git: \(error)"
    case .clone(let path, let detail): "cloning \(path): \(detail)"
    case .pool(let path, let detail): "worktree slot \(path): \(detail)"
    }
  }
}

/// The git mutations a build makes: task worktrees and branches. Kept apart from the read-only
/// ``Git`` so a command that only reads can't be handed one. Paths are absolute.
public protocol GitWorkspace: Sendable {
  /// Whether `refs/heads/<branch>` exists.
  func branchExists(_ branch: String) async throws(GitWorkspaceError) -> Bool

  /// Whether every commit on `branch` is reachable from `base`.
  func isMerged(_ branch: String, into base: String) async throws(GitWorkspaceError) -> Bool

  /// `git worktree add <path> -b <branch> <base>`.
  func addWorktree(at path: String, branch: String, from base: String)
    async throws(GitWorkspaceError)

  /// `git worktree remove`; `force` also discards a dirty or untracked tree.
  func removeWorktree(at path: String, force: Bool) async throws(GitWorkspaceError)

  /// In the existing worktree at `path`, `git switch -c <branch> <base>`.
  func switchWorktree(at path: String, toNewBranch branch: String, from base: String)
    async throws(GitWorkspaceError)

  /// The worktree's tracked changes and untracked files, ignored files left out.
  func uncommittedPaths(inWorktree path: String) async throws(GitWorkspaceError) -> [String]

  /// Detaches the worktree's `HEAD`, discards its tracked changes and deletes its untracked
  /// files. Ignored files, such as build directories, stay.
  func resetWorktree(at path: String) async throws(GitWorkspaceError)

  /// Deletes the local branch whatever it is merged into; callers check that first.
  func deleteBranch(_ branch: String) async throws(GitWorkspaceError)

  /// Creates `refs/heads/<branch>` at `commit`; fails when the branch exists.
  func createBranch(_ branch: String, at commit: String) async throws(GitWorkspaceError)

  /// The local branches whose history holds `commit`, sorted.
  func branches(containing commit: String) async throws(GitWorkspaceError) -> [String]

  /// APFS-clones each of `relativePaths` from `source` into `destination` at the same relative
  /// path, then deletes every `ModuleCache` directory inside the clones, whose headers record the
  /// source's absolute path. A path missing from `source` is skipped.
  /// - Returns: the relative paths cloned.
  func cloneWarmBuild(_ relativePaths: [String], from source: String, into destination: String)
    async throws(GitWorkspaceError) -> [String]
}

/// Where a build task's worktree and branch live, and the checkout and branch it merges into.
///
/// The worktree is the sibling `<repo>-<plan>-<task>` of the main checkout in both profiles, and
/// the task branch is `<plan>/<task>`. In an owned repository (spec §4) it is cut from `main`, and
/// merges land in the main checkout. In a brownfield clone nothing touches the user's checkout or
/// branch: it is cut from the plan branch, and merges land in that branch's own checkout, the
/// sibling `<repo>-<plan>`. Neither sits under the git dir: the plan-state guard owns every file in
/// a plan's directory, and dev servers such as Vite refuse to serve files under `.git`. A brownfield
/// task or fix branch checked out in a ``WorktreePool`` slot has that slot's path instead.
public struct TaskWorktree: Sendable, Equatable {
  public static let base = "main"

  /// The checkout merges land in: the main checkout, or a brownfield plan's checkout.
  public let mainCheckout: String
  public let path: String
  public let branch: String
  /// The branch task branches are cut from and merged into.
  public let baseBranch: String
  /// The git common dir the names were derived from.
  public let commonDirectory: String
  /// The plan's slug.
  public let plan: String

  /// - Throws: ``GitWorkspaceError/git(_:)`` when `commonDirectory` isn't a checkout's `.git`, or
  ///   in a brownfield clone when `plan` isn't 1 path component.
  public init(
    commonDirectory: String, plan: String, task: String, profile: RepositoryProfile = .owned
  ) throws(GitWorkspaceError) {
    let branch = "\(plan)/\(task)"
    self.branch = branch
    self.commonDirectory = commonDirectory
    self.plan = plan
    let own = try Self.sibling(commonDirectory: commonDirectory, named: "\(plan)-\(task)")
    switch profile {
    case .owned:
      path = own
      mainCheckout = try Self.mainCheckout(commonDirectory: commonDirectory)
      baseBranch = Self.base
    case .brownfield:
      mainCheckout = try Self.planCheckout(commonDirectory: commonDirectory, plan: plan)
      baseBranch = BrownfieldRunReport.planBranch(slug: plan)
      path =
        try WorktreePool(commonDirectory: commonDirectory, plan: plan).path(holding: branch)
        ?? own
    }
  }

  /// A brownfield plan's checkout of its plan branch: the sibling `<repo>-<plan>` of the user's
  /// checkout, where the orchestrator commits the contract, `build merge` lands each task and the
  /// `merge` and `final` gates run. Every caller that creates, finds or removes that checkout
  /// names it through this function.
  /// - Throws: ``GitWorkspaceError/git(_:)`` for a plan name that isn't 1 path component, or a
  ///   `commonDirectory` that isn't an absolute checkout's `.git`.
  public static func planCheckout(commonDirectory: String, plan: String)
    throws(GitWorkspaceError) -> String
  {
    do throws(PlanStateLayoutError) {
      _ = try PlanStateLayout(commonDirectory: commonDirectory).plan(plan)
    } catch {
      throw .git(.unparseableOutput(command: "rev-parse --git-common-dir", detail: "\(error)"))
    }
    return try sibling(commonDirectory: commonDirectory, named: plan)
  }

  /// A brownfield plan's pooled worktree slot `<repo>-<plan>.slot-<number>`, beside the main
  /// checkout (``WorktreePool``). The `.` keeps it apart from every `<repo>-<plan>-<task>`.
  /// - Throws: ``GitWorkspaceError/git(_:)`` for a `commonDirectory` that isn't a checkout's `.git`.
  public static func slotPath(commonDirectory: String, plan: String, number: Int)
    throws(GitWorkspaceError) -> String
  {
    try sibling(commonDirectory: commonDirectory, named: "\(plan).slot-\(number)")
  }

  /// `<repo>-<suffix>` beside the main checkout `<repo>`.
  private static func sibling(commonDirectory: String, named suffix: String)
    throws(GitWorkspaceError) -> String
  {
    let main = URL(
      filePath: try mainCheckout(commonDirectory: commonDirectory), directoryHint: .isDirectory)
    return main.deletingLastPathComponent()
      .appending(path: "\(main.lastPathComponent)-\(suffix)").path
  }

  /// The checkout whose `.git` is `commonDirectory`, the same from every linked worktree.
  /// - Throws: ``GitWorkspaceError/git(_:)`` for a bare repository, which has no main checkout to
  ///   name worktrees after or clone builds from.
  public static func mainCheckout(commonDirectory: String) throws(GitWorkspaceError) -> String {
    let common = URL(filePath: commonDirectory, directoryHint: .isDirectory)
    guard common.lastPathComponent == ".git" else {
      throw .git(
        .unparseableOutput(
          command: "rev-parse --git-common-dir",
          detail: "\(commonDirectory) isn't a checkout's .git, so there is no main checkout"))
    }
    return common.deletingLastPathComponent().path
  }
}

/// The warm build `worktree create` clones: every configured package's `.build` plus the
/// per-worktree DerivedData (Foundation spec §4.4), as checkout-relative paths.
public enum WarmBuild {
  public struct Survey: Sendable, Equatable {
    /// Package `.build` directories that exist, sorted.
    public let packageBuilds: [String]
    /// Package `.build` directories that don't.
    public let missingPackageBuilds: [String]
    /// The DerivedData directory, when it exists.
    public let derivedData: String?

    /// Nothing to clone and nothing missing: what a brownfield worktree gets, since its clone
    /// configures no packages.
    public static let nothing = Survey(
      packageBuilds: [], missingPackageBuilds: [], derivedData: nil)

    /// Everything there is to clone.
    public var clonable: [String] { packageBuilds + (derivedData.map { [$0] } ?? []) }
  }

  public static func buildDirectory(ofPackage package: String) -> String {
    package.isEmpty || package == "." ? ".build" : "\(package)/.build"
  }

  public static func survey(packageDirectories: [String], in checkout: String) -> Survey {
    let root = URL(filePath: checkout, directoryHint: .isDirectory)
    let exists = { (relative: String) in
      var isDirectory: ObjCBool = false
      return FileManager.default.fileExists(
        atPath: root.appending(path: relative).path, isDirectory: &isDirectory)
        && isDirectory.boolValue
    }
    let builds = packageDirectories.map(buildDirectory(ofPackage:)).sorted()
    // Only a state root inside the tree sits at the same relative path in every worktree.
    let derivedData: String? =
      switch StateRootResolver.resolve(worktree: root) {
      case .tree: RunLayout.treePath(RunLayout.derivedDataDirectory)
      case .gitDir: nil
      }
    return Survey(
      packageBuilds: builds.filter(exists), missingPackageBuilds: builds.filter { !exists($0) },
      derivedData: derivedData.flatMap { exists($0) ? $0 : nil })
  }
}

/// The branch writes a sprint makes: it creates `sprint/<slug>` and fast-forwards `main`, and never
/// merges or rebases. Kept apart from ``GitWorkspace`` so a sprint can't be handed worktree writes.
public protocol SprintBranches: Sendable {
  /// The branch `HEAD` is on, or `nil` when `HEAD` is detached.
  func currentBranch() async throws(GitWorkspaceError) -> String?

  /// Every branch some worktree of the repository has checked out.
  func checkedOutBranches() async throws(GitWorkspaceError) -> [String]

  /// Creates `refs/heads/<branch>` at `commit`; fails when the branch exists.
  func createBranch(_ branch: String, at commit: String) async throws(GitWorkspaceError)

  /// Deletes `branch` only while it is still at `commit`.
  func deleteBranch(_ branch: String, at commit: String) async throws(GitWorkspaceError)

  /// Moves `branch` from `old` to `new` when `old` is an ancestor of `new`, and only while `branch`
  /// is still at `old`.
  /// - Returns: `false`, moving nothing, when `new` doesn't descend from `old`.
  func fastForward(_ branch: String, from old: String, to new: String)
    async throws(GitWorkspaceError) -> Bool
}

/// ``SprintBranches`` over `git`.
public struct LiveSprintBranches: SprintBranches {
  private let runner: any ProcessRunner
  private let repositoryRoot: String
  private let timeout: Duration

  /// - Parameter repositoryRoot: any directory inside the repository.
  public init(runner: any ProcessRunner, repositoryRoot: String, timeout: Duration = .seconds(60)) {
    self.runner = runner
    self.repositoryRoot = repositoryRoot
    self.timeout = timeout
  }

  public func currentBranch() async throws(GitWorkspaceError) -> String? {
    let arguments = ["symbolic-ref", "--quiet", "--short", "HEAD"]
    let output = try await git(arguments)
    // `--quiet` makes a detached HEAD exit 1 with no diagnostics.
    guard try Self.yesOrNo(output, arguments) else { return nil }
    return output.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public func checkedOutBranches() async throws(GitWorkspaceError) -> [String] {
    let prefix = "branch refs/heads/"
    return try await succeed(["worktree", "list", "--porcelain"])
      .split(separator: "\n")
      .filter { $0.hasPrefix(prefix) }
      .map { String($0.dropFirst(prefix.count)) }
  }

  public func createBranch(_ branch: String, at commit: String) async throws(GitWorkspaceError) {
    try Self.checkRef(branch)
    try Self.checkRef(commit)
    _ = try await succeed(["branch", "--no-track", branch, commit])
  }

  public func deleteBranch(_ branch: String, at commit: String) async throws(GitWorkspaceError) {
    try Self.checkRef(branch)
    try Self.checkRef(commit)
    _ = try await succeed(["update-ref", "-d", "refs/heads/\(branch)", commit])
  }

  public func fastForward(_ branch: String, from old: String, to new: String)
    async throws(GitWorkspaceError) -> Bool
  {
    try Self.checkRef(branch)
    try Self.checkRef(old)
    try Self.checkRef(new)
    let ancestry = ["merge-base", "--is-ancestor", old, new]
    guard try Self.yesOrNo(try await git(ancestry), ancestry) else { return false }
    // The old value makes the move compare-and-swap: a commit that landed since fails it.
    _ = try await succeed([
      "update-ref", "-m", "sprint finish: fast-forward", "refs/heads/\(branch)", new, old,
    ])
    return true
  }

  private static func checkRef(_ ref: String) throws(GitWorkspaceError) {
    if ref.isEmpty || ref.hasPrefix("-") { throw .git(.invalidRef(ref)) }
  }

  /// Exit 0 is yes and exit 1 is no; anything else is git failing to answer.
  private static func yesOrNo(_ output: ProcessOutput, _ arguments: [String])
    throws(GitWorkspaceError) -> Bool
  {
    switch output.status {
    case .exited(0): return true
    case .exited(1): return false
    default:
      throw .git(
        .commandFailed(arguments: arguments, status: output.status, stderr: output.stderr.text))
    }
  }

  private func succeed(_ arguments: [String]) async throws(GitWorkspaceError) -> String {
    let output = try await git(arguments)
    guard output.status.isSuccess else {
      throw .git(
        .commandFailed(arguments: arguments, status: output.status, stderr: output.stderr.text))
    }
    return output.stdout.text
  }

  private func git(_ arguments: [String]) async throws(GitWorkspaceError) -> ProcessOutput {
    do {
      return try await runner.run(
        ProcessInvocation(
          executable: "git", arguments: arguments, workingDirectory: repositoryRoot,
          timeout: timeout))
    } catch {
      throw .git(.process(error))
    }
  }
}

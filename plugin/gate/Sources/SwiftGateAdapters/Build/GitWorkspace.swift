import Foundation
import SwiftGateDomain

/// Why a worktree or branch mutation, or a warm-build clone, failed. Never evidence about the code.
public enum GitWorkspaceError: Error, Sendable, Equatable, CustomStringConvertible {
  case git(GitError)
  case clone(path: String, detail: String)

  public var verdict: Verdict { .blocked }

  public var description: String {
    switch self {
    case .git(.commandFailed(let arguments, let status, let stderr)):
      "git \(arguments.joined(separator: " ")) failed (\(status)): "
        + stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    case .git(let error): "git: \(error)"
    case .clone(let path, let detail): "cloning \(path): \(detail)"
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

  /// Deletes the local branch whatever it is merged into; callers check that first.
  func deleteBranch(_ branch: String) async throws(GitWorkspaceError)

  /// APFS-clones each of `relativePaths` from `source` into `destination` at the same relative
  /// path, then deletes every `ModuleCache` directory inside the clones, whose headers record the
  /// source's absolute path. A path missing from `source` is skipped.
  /// - Returns: the relative paths cloned.
  func cloneWarmBuild(_ relativePaths: [String], from source: String, into destination: String)
    async throws(GitWorkspaceError) -> [String]
}

/// Where a build task's worktree and branch live (spec §4): the sibling
/// `<repo>-<plan>-<task>` of the main checkout, on branch `<plan>/<task>` cut from `main`.
public struct TaskWorktree: Sendable, Equatable {
  public static let base = "main"

  /// The checkout holding the git common dir; its directory name is `<repo>`.
  public let mainCheckout: String
  public let path: String
  public let branch: String

  /// - Throws: ``GitWorkspaceError/git(_:)`` when `commonDirectory` isn't a checkout's `.git`.
  public init(commonDirectory: String, plan: String, task: String) throws(GitWorkspaceError) {
    let main = URL(
      filePath: try Self.mainCheckout(commonDirectory: commonDirectory),
      directoryHint: .isDirectory)
    mainCheckout = main.path
    path =
      main.deletingLastPathComponent()
      .appending(path: "\(main.lastPathComponent)-\(plan)-\(task)").path
    branch = "\(plan)/\(task)"
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
    return Survey(
      packageBuilds: builds.filter(exists), missingPackageBuilds: builds.filter { !exists($0) },
      derivedData: exists(HarnessGC.derivedDataDirectory) ? HarnessGC.derivedDataDirectory : nil)
  }
}

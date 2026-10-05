import Foundation
import SwiftGateDomain

/// ``GitWorkspace`` over `git`, `/bin/cp` and `/usr/bin/find`. The copy and find tools are named by
/// absolute path: a shell wrapper or alias of the same name can drop `-c` and copy gigabytes, or
/// prompt, without saying so.
public struct LiveGitWorkspace: GitWorkspace {
  static let copy = "/bin/cp"
  static let find = "/usr/bin/find"
  static let remove = "/bin/rm"
  /// SwiftPM's is `ModuleCache`; xcodebuild's inside a DerivedData directory is
  /// `ModuleCache.noindex`. Both record the absolute path they were built at.
  static let moduleCacheNames = ["ModuleCache", "ModuleCache.noindex"]

  private let runner: any ProcessRunner
  private let repositoryRoot: String
  private let timeout: Duration

  /// - Parameter repositoryRoot: any directory inside the repository.
  public init(
    runner: any ProcessRunner, repositoryRoot: String, timeout: Duration = .seconds(600)
  ) {
    self.runner = runner
    self.repositoryRoot = repositoryRoot
    self.timeout = timeout
  }

  public func branchExists(_ branch: String) async throws(GitWorkspaceError) -> Bool {
    try Self.checkRef(branch)
    let output = try await git(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"])
    return try Self.yesOrNo(output, ["rev-parse", "--verify", "refs/heads/\(branch)"])
  }

  public func isMerged(_ branch: String, into base: String) async throws(GitWorkspaceError)
    -> Bool
  {
    try Self.checkRef(branch)
    try Self.checkRef(base)
    let arguments = ["merge-base", "--is-ancestor", "refs/heads/\(branch)", base]
    return try Self.yesOrNo(try await git(arguments), arguments)
  }

  public func addWorktree(at path: String, branch: String, from base: String)
    async throws(GitWorkspaceError)
  {
    try Self.checkRef(branch)
    try Self.checkRef(base)
    try await succeed(["worktree", "add", "--quiet", "-b", branch, "--", path, base])
  }

  /// Adds a worktree at `path` on `branch`, which must already exist.
  public func checkOutWorktree(at path: String, branch: String) async throws(GitWorkspaceError) {
    try Self.checkRef(branch)
    try await succeed(["worktree", "add", "--quiet", "--", path, branch])
  }

  public func removeWorktree(at path: String, force: Bool) async throws(GitWorkspaceError) {
    try await succeed(
      ["worktree", "remove"] + (force ? ["--force", "--force"] : []) + ["--", path])
  }

  public func switchWorktree(at path: String, toNewBranch branch: String, from base: String)
    async throws(GitWorkspaceError)
  {
    try Self.checkRef(branch)
    try Self.checkRef(base)
    try await succeed(["-C", path, "switch", "--quiet", "--no-track", "-c", branch, base])
  }

  public func addDetachedWorktree(at path: String, revision: String)
    async throws(GitWorkspaceError)
  {
    try Self.checkRef(revision)
    try await succeed(["worktree", "add", "--quiet", "--detach", "--", path, revision])
  }

  public func detachWorktree(at path: String, revision: String) async throws(GitWorkspaceError) {
    try Self.checkRef(revision)
    try await succeed(["-C", path, "switch", "--quiet", "--detach", revision])
  }

  public func uncommittedPaths(inWorktree path: String) async throws(GitWorkspaceError)
    -> [String]
  {
    let arguments = ["-C", path, "status", "--porcelain=v1", "--untracked-files=all"]
    let output = try await git(arguments)
    guard output.status.isSuccess else {
      throw .git(
        .commandFailed(arguments: arguments, status: output.status, stderr: output.stderr.text))
    }
    return output.stdout.text.split(separator: "\n").map { String($0.dropFirst(3)) }
  }

  public func resetWorktree(at path: String) async throws(GitWorkspaceError) {
    // Reset first: it also ends a conflicted merge, which `switch` refuses to leave.
    try await succeed(["-C", path, "reset", "--quiet", "--hard"])
    try await succeed(["-C", path, "switch", "--quiet", "--detach"])
    try await succeed(["-C", path, "clean", "-ffdq"])
  }

  public func deleteBranch(_ branch: String) async throws(GitWorkspaceError) {
    try Self.checkRef(branch)
    try await succeed(["branch", "--quiet", "-D", "--", branch])
  }

  public func createBranch(_ branch: String, at commit: String) async throws(GitWorkspaceError) {
    try Self.checkRef(branch)
    try Self.checkRef(commit)
    try await succeed(["branch", "--quiet", "--no-track", "--", branch, commit])
  }

  public func branches(containing commit: String) async throws(GitWorkspaceError) -> [String] {
    try Self.checkRef(commit)
    let arguments = ["branch", "--list", "--contains", commit, "--format=%(refname:short)"]
    let output = try await git(arguments)
    guard output.status.isSuccess else {
      throw .git(
        .commandFailed(arguments: arguments, status: output.status, stderr: output.stderr.text))
    }
    return output.stdout.text.split(separator: "\n").map(String.init).sorted()
  }

  public func cloneWarmBuild(
    _ relativePaths: [String], from source: String, into destination: String
  ) async throws(GitWorkspaceError) -> [String] {
    let sourceRoot = URL(filePath: source, directoryHint: .isDirectory)
    let destinationRoot = URL(filePath: destination, directoryHint: .isDirectory)
    var cloned: [String] = []
    for relative in relativePaths {
      let from = sourceRoot.appending(path: relative)
      let to = destinationRoot.appending(path: relative)
      guard FileManager.default.fileExists(atPath: from.path) else { continue }
      guard !FileManager.default.fileExists(atPath: to.path) else {
        throw .clone(path: to.path, detail: "already exists in the new worktree")
      }
      do {
        try FileManager.default.createDirectory(
          at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
      } catch {
        throw .clone(path: to.path, detail: error.localizedDescription)
      }
      try await tool(Self.copy, ["-c", "-R", from.path, to.path], cloning: to.path)
      var pruned: [String] = [to.path, "-type", "d", "("]
      for (index, name) in Self.moduleCacheNames.enumerated() {
        pruned += (index == 0 ? [] : ["-o"]) + ["-name", name]
      }
      pruned += [")", "-prune", "-exec", Self.remove, "-rf", "{}", "+"]
      try await tool(Self.find, pruned, cloning: to.path)
      cloned.append(relative)
    }
    return cloned
  }

  private func tool(_ executable: String, _ arguments: [String], cloning path: String)
    async throws(GitWorkspaceError)
  {
    let output: ProcessOutput
    do {
      output = try await runner.run(
        ProcessInvocation(executable: executable, arguments: arguments, timeout: timeout))
    } catch {
      throw .clone(path: path, detail: "\(executable): \(error)")
    }
    guard output.status.isSuccess else {
      throw .clone(
        path: path,
        detail: "\(executable) \(arguments.joined(separator: " ")) exited \(output.status): "
          + output.stderr.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }

  private static func checkRef(_ ref: String) throws(GitWorkspaceError) {
    if ref.isEmpty || ref.hasPrefix("-") { throw .git(.invalidRef(ref)) }
  }

  /// Exit 0 is yes and exit 1 is no, as `rev-parse --verify --quiet` and
  /// `merge-base --is-ancestor` answer; anything else is git failing to answer.
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

  private func succeed(_ arguments: [String]) async throws(GitWorkspaceError) {
    let output = try await git(arguments)
    guard output.status.isSuccess else {
      throw .git(
        .commandFailed(arguments: arguments, status: output.status, stderr: output.stderr.text))
    }
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

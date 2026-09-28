import Foundation
import SwiftGateDomain

/// Reads what `surface-check` judges: a commit's Swift files against its first parent.
public protocol SurfaceCommitReading: Sendable {
  func read(_ commit: String) async throws(SurfaceReadError) -> SurfaceCommit

  /// Every Swift file in the parent's tree, by toplevel-relative path.
  func parentSwiftSources(of surface: SurfaceCommit) async throws(SurfaceReadError) -> [String:
    String]
}

/// Every case means the commit couldn't be read, which is never evidence about the code.
public enum SurfaceReadError: Error, Sendable, Equatable {
  case unknownCommit(String)
  /// A root commit, or one whose parent the object database doesn't hold (a shallow clone).
  case parentUnavailable(commit: String)
  /// git listed a changed path that neither the commit nor its parent holds.
  case missingPath(String)
  case git(GitError)
}

/// ``SurfaceCommitReading`` over the `git` CLI.
public struct LiveSurfaceCommitReader: SurfaceCommitReading {
  private let runner: any ProcessRunner
  private let repositoryRoot: String
  private let git: LiveGit

  public init(runner: any ProcessRunner, repositoryRoot: String) {
    self.runner = runner
    self.repositoryRoot = repositoryRoot
    git = LiveGit(runner: runner, repositoryRoot: repositoryRoot)
  }

  public func read(_ commit: String) async throws(SurfaceReadError) -> SurfaceCommit {
    guard
      let sha = try await gitCall({ () async throws(GitError) in try await git.revision(commit) })
    else { throw .unknownCommit(commit) }
    // A root commit has no `^1`; a shallow clone names the parent but lacks its object, so peeling
    // it to a commit fails the same way.
    guard
      let parent = try await gitCall({ () async throws(GitError) in
        try await git.revision("\(sha)^1")
      })
    else { throw .parentUnavailable(commit: sha) }
    let changed = try await gitCall { () async throws(GitError) in
      try await git.changedFiles(from: parent, to: sha)
    }
    let swift = changed.filter { $0.hasSuffix(".swift") }
    let parentTexts = try await gitCall { () async throws(GitError) in
      try await git.contents(of: swift, at: parent)
    }
    let commitTexts = try await gitCall { () async throws(GitError) in
      try await git.contents(of: swift, at: sha)
    }
    var changes: [SurfaceFileChange] = []
    for path in changed where path.hasSuffix(".swift") {
      let before = parentTexts[path]
      let after = commitTexts[path]
      if before == nil, after == nil { throw .missingPath(path) }
      changes.append(SurfaceFileChange(path: path, parentText: before, commitText: after))
    }
    return SurfaceCommit(
      commit: sha, parent: parent, changes: changes,
      otherPaths: changed.filter { !$0.hasSuffix(".swift") })
  }

  public func parentSwiftSources(of surface: SurfaceCommit) async throws(SurfaceReadError)
    -> [String: String]
  {
    let arguments = ["ls-tree", "-r", "-z", "--full-tree", "--name-only", surface.parent]
    let output: ProcessOutput
    do {
      output = try await runner.run(
        ProcessInvocation(
          executable: "git", arguments: arguments, workingDirectory: repositoryRoot,
          timeout: .seconds(60)))
    } catch {
      throw .git(.process(error))
    }
    guard output.status.isSuccess, !output.stdout.truncated else {
      throw .git(
        .commandFailed(arguments: arguments, status: output.status, stderr: output.stderr.text))
    }
    let paths = output.stdout.text.split(separator: "\0").map(String.init)
      .filter { $0.hasSuffix(".swift") }
    let sources = try await gitCall { () async throws(GitError) in
      try await git.contents(of: paths, at: surface.parent)
    }
    if let missing = paths.first(where: { sources[$0] == nil }) { throw .missingPath(missing) }
    return sources
  }

  private func gitCall<T>(_ body: () async throws(GitError) -> T) async throws(SurfaceReadError)
    -> T
  {
    do {
      return try await body()
    } catch {
      throw .git(error)
    }
  }
}

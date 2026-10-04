import Foundation
import SwiftGateDomain

public enum GitTrackedTreeError: Error, Sendable, Equatable {
  case git(arguments: [String], reason: String)
  /// The repository has no commit, so discovery has no tree to read.
  case noCommit

  public var message: String {
    switch self {
    case .git(let arguments, let reason): "git \(arguments.joined(separator: " ")): \(reason)"
    case .noCommit: "the repository has no commit to discover"
    }
  }
}

/// The repository discover reads, through git alone: its tracked files, `HEAD`, the files already
/// modified, and where its state lives.
public struct GitTrackedTree: Sendable {
  private let runner: any ProcessRunner
  /// The directory git runs in; any directory inside the worktree.
  public let directory: URL

  public init(runner: any ProcessRunner, directory: URL) {
    self.runner = runner
    self.directory = directory
  }

  /// The worktree's top level.
  public func repositoryRoot() async throws(GitTrackedTreeError) -> URL {
    URL(filePath: try await line(["rev-parse", "--show-toplevel"]), directoryHint: .isDirectory)
  }

  /// `git ls-files -z` once; each file's bytes are read from the worktree only when a reader asks,
  /// and a path the listing doesn't hold reads as `nil`.
  public func snapshot() async throws(GitTrackedTreeError) -> TrackedTreeSnapshot {
    let root = try await repositoryRoot()
    let paths = try await git(["ls-files", "-z"]).split(separator: "\0").map(String.init)
    let tracked = Set(paths)
    return TrackedTreeSnapshot(
      paths: paths,
      read: { path in
        guard tracked.contains(path) else { return nil }
        return FileManager.default.contents(atPath: root.appending(path: path).path)
      })
  }

  /// The `HEAD` sha.
  public func head() async throws(GitTrackedTreeError) -> String {
    let output = try await run(["rev-parse", "--verify", "--quiet", "HEAD"])
    let sha = output.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard output.status.isSuccess, !sha.isEmpty else { throw .noCommit }
    return sha
  }

  /// Modified, staged and untracked paths, as `git status --porcelain` names them: an untracked
  /// directory once, ending in `/`, and a rename under its new path.
  public func dirtyPaths() async throws(GitTrackedTreeError) -> [String] {
    let fields = try await git(["status", "--porcelain=v1", "-z", "--untracked-files=normal"])
      .split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    var paths: [String] = []
    var index = 0
    while index < fields.count {
      let entry = fields[index]
      index += 1
      guard entry.count > 3 else { continue }
      let status = entry.prefix(2)
      paths.append(String(entry.dropFirst(3)))
      // A rename or copy carries its old path as the next field.
      if status.contains("R") || status.contains("C") { index += 1 }
    }
    return paths.sorted()
  }

  /// The clone's state paths, from `git rev-parse --git-common-dir` and `--git-dir`.
  public func stateLayout() async throws(GitTrackedTreeError) -> BrownfieldStateLayout {
    let lines = try await git([
      "rev-parse", "--path-format=absolute", "--git-common-dir", "--git-dir",
    ]).split(separator: "\n").map(String.init)
    guard lines.count == 2 else {
      throw .git(arguments: ["rev-parse", "--git-common-dir", "--git-dir"], reason: "\(lines)")
    }
    return BrownfieldStateLayout(
      commonDir: URL(filePath: lines[0], directoryHint: .isDirectory),
      gitDir: URL(filePath: lines[1], directoryHint: .isDirectory))
  }

  private func line(_ arguments: [String]) async throws(GitTrackedTreeError) -> String {
    try await git(arguments).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func git(_ arguments: [String]) async throws(GitTrackedTreeError) -> String {
    let output = try await run(arguments)
    guard output.status.isSuccess else {
      throw .git(
        arguments: arguments,
        reason: output.stderr.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return output.stdout.text
  }

  private func run(_ arguments: [String]) async throws(GitTrackedTreeError) -> ProcessOutput {
    do {
      return try await runner.run(
        ProcessInvocation(
          executable: "git", arguments: ["-c", "core.quotePath=false"] + arguments,
          workingDirectory: directory.path, timeout: .seconds(60)))
    } catch {
      throw .git(arguments: arguments, reason: String(describing: error))
    }
  }
}

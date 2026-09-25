import Foundation
import SwiftGateDomain

/// The tree `prove` runs tests in: `revision` checked out, then `copiedPaths` taken from the
/// working tree (so uncommitted and untracked work counts) and `revertedPaths` restored to
/// `revertTo`. A path absent from its source is absent from the scratch tree. Paths are
/// toplevel-relative.
public struct ScratchTreeRequest: Sendable, Equatable {
  public var revision: String
  public var revertTo: String
  public var copiedPaths: [String]
  public var revertedPaths: [String]

  public init(revision: String, revertTo: String, copiedPaths: [String], revertedPaths: [String]) {
    self.revision = revision
    self.revertTo = revertTo
    self.copiedPaths = copiedPaths
    self.revertedPaths = revertedPaths
  }
}

/// A scratch tree could not be made: never evidence about the code.
public enum ScratchWorktreeError: Error, Sendable, Equatable {
  case git(GitError)
  case fileSystem(String)

  public var verdict: Verdict { .blocked }
}

/// Makes a throwaway git worktree, hands its toplevel to `body`, and always removes it.
public protocol ScratchWorktrees: Sendable {
  func withScratchTree<T: Sendable>(
    _ request: ScratchTreeRequest, _ body: (URL) async -> T
  ) async throws(ScratchWorktreeError) -> T
}

/// ``ScratchWorktrees`` over `git worktree`. Trees are hidden siblings of the repository's
/// toplevel, `.<repo>-swiftgate-prove-<pid>-<token>`, so a tree whose process died (a killed run
/// skips its cleanup) is recognisable and swept by the next run.
///
/// Beside the repository rather than in the system temporary directory so a scratch build shares
/// the repository's volume and its orphans are found by name next to it.
public struct LiveScratchWorktrees: ScratchWorktrees {
  static let nameMarker = "-swiftgate-prove-"

  private let runner: any ProcessRunner
  private let repositoryRoot: String
  private let directory: URL?
  private let timeout: Duration

  /// - Parameters:
  ///   - repositoryRoot: any directory inside the repository.
  ///   - directory: where scratch trees are made; `nil` for beside the repository's toplevel.
  public init(
    runner: any ProcessRunner, repositoryRoot: String, directory: URL? = nil,
    timeout: Duration = .seconds(300)
  ) {
    self.runner = runner
    self.repositoryRoot = repositoryRoot
    self.directory = directory?.standardizedFileURL
    self.timeout = timeout
  }

  public func withScratchTree<T: Sendable>(
    _ request: ScratchTreeRequest, _ body: (URL) async -> T
  ) async throws(ScratchWorktreeError) -> T {
    for ref in [request.revision, request.revertTo] where ref.hasPrefix("-") {
      throw .git(.invalidRef(ref))
    }
    let toplevel = URL(
      filePath: try await git(["rev-parse", "--show-toplevel"], in: repositoryRoot)
        .trimmingCharacters(in: .whitespacesAndNewlines),
      directoryHint: .isDirectory)
    let parent = directory ?? toplevel.deletingLastPathComponent()
    let prefix = ".\(toplevel.lastPathComponent)\(Self.nameMarker)"
    await sweepOrphans(in: parent, prefix: prefix, toplevel: toplevel)

    let token = UInt32.random(in: .min ... .max)  // swiftgate:allow det.random — unique name
    let scratch = parent.appending(
      path:
        "\(prefix)\(ProcessInfo.processInfo.processIdentifier)-\(String(token, radix: 16))",
      directoryHint: .isDirectory)
    do throws(ScratchWorktreeError) {
      _ = try await git(
        ["worktree", "add", "--detach", "--quiet", scratch.path, request.revision],
        in: toplevel.path)
    } catch {
      try? FileManager.default.removeItem(at: scratch)
      throw error
    }
    do throws(ScratchWorktreeError) {
      try await populate(scratch, from: toplevel, request)
    } catch {
      await remove(scratch, toplevel: toplevel)
      throw error
    }
    let result = await body(scratch)
    await remove(scratch, toplevel: toplevel)
    return result
  }

  private func populate(_ scratch: URL, from toplevel: URL, _ request: ScratchTreeRequest)
    async throws(ScratchWorktreeError)
  {
    _ = try await git(
      ["rev-parse", "--verify", "--quiet", "\(request.revertTo)^{commit}"], in: scratch.path)
    let files = FileManager.default
    do {
      for path in request.copiedPaths {
        let source = toplevel.appending(path: path)
        let destination = scratch.appending(path: path)
        if files.fileExists(atPath: destination.path) { try files.removeItem(at: destination) }
        guard files.fileExists(atPath: source.path) else { continue }
        try files.createDirectory(
          at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.copyItem(at: source, to: destination)
      }
    } catch {
      throw .fileSystem("copying the working tree into \(scratch.path): \(error)")
    }
    guard !request.revertedPaths.isEmpty else { return }
    let listed = try await git(
      ["ls-tree", "-r", "-z", "--name-only", request.revertTo, "--"] + request.revertedPaths,
      in: scratch.path)
    let existing = Set(listed.split(separator: "\0").map(String.init))
    if !existing.isEmpty {
      _ = try await git(
        ["checkout", "--quiet", request.revertTo, "--"] + existing.sorted(), in: scratch.path)
    }
    do {
      for path in request.revertedPaths where !existing.contains(path) {
        let destination = scratch.appending(path: path)
        if files.fileExists(atPath: destination.path) { try files.removeItem(at: destination) }
      }
    } catch {
      throw .fileSystem("removing files added since \(request.revertTo): \(error)")
    }
  }

  private func remove(_ scratch: URL, toplevel: URL) async {
    _ = try? await git(
      ["worktree", "remove", "--force", "--force", scratch.path], in: toplevel.path)
    if FileManager.default.fileExists(atPath: scratch.path) {
      try? FileManager.default.removeItem(at: scratch)
      _ = try? await git(["worktree", "prune"], in: toplevel.path)
    }
  }

  /// Removes scratch trees whose owning process no longer exists, then drops their registrations.
  private func sweepOrphans(in parent: URL, prefix: String, toplevel: URL) async {
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
    var removed = false
    for entry in entries where entry.hasPrefix(prefix) {
      let fields = entry.dropFirst(prefix.count).split(separator: "-")
      guard let pid = fields.first.flatMap({ Int32($0) }), pid > 0,
        kill(pid, 0) == -1, errno == ESRCH
      else { continue }
      try? FileManager.default.removeItem(at: parent.appending(path: entry))
      removed = true
    }
    if removed { _ = try? await git(["worktree", "prune"], in: toplevel.path) }
  }

  private func git(_ arguments: [String], in directory: String) async throws(ScratchWorktreeError)
    -> String
  {
    let invocation = ProcessInvocation(
      executable: "git", arguments: ["--literal-pathspecs"] + arguments,
      workingDirectory: directory, timeout: timeout)
    let output: ProcessOutput
    do {
      output = try await runner.run(invocation)
    } catch {
      throw .git(.process(error))
    }
    guard output.status.isSuccess else {
      throw .git(
        .commandFailed(arguments: arguments, status: output.status, stderr: output.stderr.text))
    }
    return output.stdout.text
  }
}

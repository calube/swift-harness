import Foundation
import SwiftGateDomain

/// The tree `prove` runs tests in: `revision` checked out, then `copiedPaths` taken from the
/// working tree (so uncommitted and untracked work counts) and `revertedPaths` restored to
/// `revertTo`. A path absent from its source is absent from the scratch tree, except that a path
/// committed as a rename since `revertTo` gets its old content. Paths are toplevel-relative.
public struct ScratchTreeRequest: Sendable, Equatable {
  public var revision: String
  public var revertTo: String
  public var copiedPaths: [String]
  public var revertedPaths: [String]
  /// Package directories whose SwiftPM `.build` is cloned from the working tree, so a build in
  /// the scratch tree starts from the user's resolved and fetched dependencies. Best effort: a
  /// package with no `.build`, or a clone that fails, builds from scratch.
  public var seededBuildDirectories: [String]

  public init(
    revision: String, revertTo: String, copiedPaths: [String], revertedPaths: [String],
    seededBuildDirectories: [String] = []
  ) {
    self.revision = revision
    self.revertTo = revertTo
    self.copiedPaths = copiedPaths
    self.revertedPaths = revertedPaths
    self.seededBuildDirectories = seededBuildDirectories
  }
}

/// A scratch tree could not be made: never evidence about the code.
public enum ScratchWorktreeError: Error, Sendable, Equatable {
  case git(GitError)
  case fileSystem(String)

  public var verdict: Verdict { .blocked }
}

/// What ``LiveScratchWorktrees/sweepRegisteredOrphans()`` did: the trees it removed, and the ones
/// it found orphaned but could not remove.
public struct ScratchWorktreeSweep: Sendable, Equatable {
  public var removed: [String] = []
  public var failures: [String] = []

  public init(removed: [String] = [], failures: [String] = []) {
    self.removed = removed
    self.failures = failures
  }
}

/// Makes a throwaway git worktree, hands its toplevel to `body`, and always removes it.
public protocol ScratchWorktrees: Sendable {
  func withScratchTree<T: Sendable>(
    _ request: ScratchTreeRequest, _ body: (URL) async -> T
  ) async throws(ScratchWorktreeError) -> T
}

/// ``ScratchWorktrees`` over `git worktree`. Trees are hidden siblings of the repository's
/// toplevel, `.<repo>-swiftgate-prove-<pid>-<token>`, so a tree whose process died (a killed run
/// skips its cleanup) is recognisable and swept by the next run. When the toplevel's state root is
/// under its git dir, they go in that root's `scratch/` instead, so a clone the harness doesn't
/// own gains no sibling directory.
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
  ///   - directory: where scratch trees are made; `nil` for beside the repository's toplevel, or
  ///     the state root's `scratch/` when that root is under the git dir.
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
    let parent: URL
    if let directory {
      parent = directory
    } else {
      parent = try Self.defaultParent(of: toplevel)
    }
    let prefix = ".\(toplevel.lastPathComponent)\(Self.nameMarker)"
    await sweepOrphans(in: parent, prefix: prefix, toplevel: toplevel)
    _ = try? await sweepRegisteredOrphans()

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

  private static func defaultParent(of toplevel: URL) throws(ScratchWorktreeError) -> URL {
    let state = StateRootResolver.resolve(worktree: toplevel)
    guard case .gitDir = state else { return toplevel.deletingLastPathComponent() }
    let parent = state.url(RunLayout.scratchDirectory, directoryHint: .isDirectory)
    do {
      try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    } catch {
      throw .fileSystem("creating \(parent.path): \(error)")
    }
    return parent
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
    for directory in request.seededBuildDirectories {
      Self.seedBuild(
        from: toplevel.appending(path: directory), into: scratch.appending(path: directory))
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
    let added = request.revertedPaths.filter { !existing.contains($0) }
    guard !added.isEmpty else { return }
    // A file moved since `revertTo` reverts to its old content at its new path. Deleting it
    // instead would empty every module of a package that moved directory.
    let moved = try await renames(from: request.revertTo, to: request.revision, in: scratch)
    for path in added {
      let destination = scratch.appending(path: path)
      do {
        if files.fileExists(atPath: destination.path) { try files.removeItem(at: destination) }
      } catch {
        throw .fileSystem("removing \(path), added since \(request.revertTo): \(error)")
      }
      guard let old = moved[path] else { continue }
      let content = try await gitData(
        ["cat-file", "blob", "\(request.revertTo):\(old)"], in: scratch.path)
      do {
        try files.createDirectory(
          at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: destination)
      } catch {
        throw .fileSystem("restoring \(old) from \(request.revertTo) as \(path): \(error)")
      }
    }
  }

  /// New path → old path for every file `git` sees as renamed between the two commits.
  private func renames(from base: String, to revision: String, in scratch: URL)
    async throws(ScratchWorktreeError) -> [String: String]
  {
    let listed = try await git(GitRenames.arguments(from: base, to: revision), in: scratch.path)
    guard let moved = GitRenames.parse(listed) else {
      throw .git(
        .unparseableOutput(command: "diff --name-status", detail: "unexpected entry in \(listed)"))
    }
    return moved
  }

  /// `copyItem` clones on APFS (metadata only, seconds for gigabytes) and copies elsewhere.
  /// SwiftPM re-plans a moved `.build` for its new paths, which keeps its fetched dependencies
  /// but not the module cache: that records its absolute path, and a moved one fails every
  /// build with "PCH was compiled with module cache path …", so it is dropped from the seed.
  private static func seedBuild(from package: URL, into destinationPackage: URL) {
    let files = FileManager.default
    let source = package.appending(path: ".build", directoryHint: .isDirectory)
    let destination = destinationPackage.appending(path: ".build", directoryHint: .isDirectory)
    guard files.fileExists(atPath: source.path), !files.fileExists(atPath: destination.path),
      files.fileExists(atPath: destinationPackage.path)
    else { return }
    do {
      try files.copyItem(at: source, to: destination)
      for platform in try files.contentsOfDirectory(atPath: destination.path) {
        let platformURL = destination.appending(path: platform)
        guard let configurations = try? files.contentsOfDirectory(atPath: platformURL.path)
        else { continue }
        for configuration in configurations {
          let cache = platformURL.appending(path: configuration).appending(path: "ModuleCache")
          if files.fileExists(atPath: cache.path) { try files.removeItem(at: cache) }
        }
      }
    } catch {
      // A partial seed could mislead the build; without one it only starts cold.
      try? files.removeItem(at: destination)
    }
  }

  /// The tree walks and deletions run off the pool: a scratch tree is a whole checkout, and
  /// deleting one takes seconds under load.
  private func remove(_ scratch: URL, toplevel: URL) async {
    // Every scratch tree has a fresh path, so SwiftPM's locks for its packages are never reused.
    await OffPool.run { TemporaryDirectories.removeSwiftPMLocks(under: scratch) }
    _ = try? await git(
      ["worktree", "remove", "--force", "--force", scratch.path], in: toplevel.path)
    if FileManager.default.fileExists(atPath: scratch.path) {
      await OffPool.run { try? FileManager.default.removeItem(at: scratch) }
      _ = try? await git(["worktree", "prune"], in: toplevel.path)
    }
  }

  /// Removes every scratch tree registered with this repository whose owning process no longer
  /// exists, whichever of its checkouts made it: a tree made from a linked worktree that has since
  /// been removed is never beside a toplevel the per-run sweep looks in.
  public func sweepRegisteredOrphans() async throws(ScratchWorktreeError) -> ScratchWorktreeSweep {
    let listed = try await git(["worktree", "list", "--porcelain"], in: repositoryRoot)
    let trees = listed.split(separator: "\n").compactMap { line -> String? in
      guard line.hasPrefix("worktree ") else { return nil }
      return String(line.dropFirst("worktree ".count))
    }
    var sweep = ScratchWorktreeSweep()
    for tree in trees {
      guard let owner = Self.owner(of: URL(filePath: tree).lastPathComponent), !Self.isAlive(owner)
      else { continue }
      await OffPool.run {
        TemporaryDirectories.removeSwiftPMLocks(
          under: URL(filePath: tree, directoryHint: .isDirectory))
      }
      do throws(ScratchWorktreeError) {
        _ = try await git(["worktree", "remove", "--force", "--force", tree], in: repositoryRoot)
        sweep.removed.append(tree)
      } catch {
        let removal = await OffPool.run {
          Result {
            if FileManager.default.fileExists(atPath: tree) {
              try FileManager.default.removeItem(atPath: tree)
            }
          }
        }
        switch removal {
        case .success: sweep.removed.append(tree)
        case .failure(let removal): sweep.failures.append("\(tree): \(error); \(removal)")
        }
      }
    }
    if !sweep.removed.isEmpty {
      _ = try await git(["worktree", "prune"], in: repositoryRoot)
    }
    return sweep
  }

  /// The owning process id in a scratch tree's name, `.<checkout>-swiftgate-prove-<pid>-<token>`.
  static func owner(of name: String) -> Int32? {
    guard name.hasPrefix("."), let marker = name.range(of: nameMarker, options: .backwards)
    else { return nil }
    let fields = name[marker.upperBound...].split(separator: "-")
    guard fields.count == 2, let pid = Int32(fields[0]) else { return nil }
    return pid
  }

  private static func isAlive(_ pid: Int32) -> Bool {
    !(kill(pid, 0) == -1 && errno == ESRCH)
  }

  /// Removes scratch trees whose owning process no longer exists, then drops their registrations.
  /// Off the pool: the parent can be a directory as large as the system temp directory.
  private func sweepOrphans(in parent: URL, prefix: String, toplevel: URL) async {
    let removed = await OffPool.run {
      let entries = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
      var removed = false
      for entry in entries where entry.hasPrefix(prefix) {
        let fields = entry.dropFirst(prefix.count).split(separator: "-")
        guard let pid = fields.first.flatMap({ Int32($0) }), pid > 0,
          kill(pid, 0) == -1, errno == ESRCH
        else { continue }
        TemporaryDirectories.remove(parent.appending(path: entry, directoryHint: .isDirectory))
        removed = true
      }
      return removed
    }
    if removed { _ = try? await git(["worktree", "prune"], in: toplevel.path) }
  }

  private func git(_ arguments: [String], in directory: String) async throws(ScratchWorktreeError)
    -> String
  {
    String(decoding: try await gitData(arguments, in: directory), as: UTF8.self)
  }

  private func gitData(_ arguments: [String], in directory: String)
    async throws(ScratchWorktreeError) -> Data
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
    return output.stdout.bytes
  }
}

/// The files `git` sees as renamed between 2 commits, as a scratch tree puts them back.
public enum GitRenames {
  /// The `git diff` that lists them, NUL-separated.
  static func arguments(from base: String, to revision: String) -> [String] {
    ["diff", "-z", "--name-status", "--find-renames", "--diff-filter=R", base, revision, "--"]
  }

  /// New path → old path from ``arguments(from:to:)``'s output; `nil` when an entry doesn't read.
  static func parse(_ listed: String) -> [String: String]? {
    var fields = listed.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[
      ...]
    var moved: [String: String] = [:]
    while let status = fields.popFirst() {
      guard status.hasPrefix("R"), let old = fields.popFirst(), let new = fields.popFirst() else {
        return nil
      }
      moved[new] = old
    }
    return moved
  }

  /// New path → old path for each file renamed from `base` to `revision` in the repository at
  /// `directory`; `nil` when git can't say.
  public static func between(
    _ base: String, _ revision: String, runner: any ProcessRunner, directory: String
  ) async -> [String: String]? {
    nil
  }
}

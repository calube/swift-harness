import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

/// Asks real git for the common dir and counts how often it was asked, which is how a test tells
/// a cache hit from a fresh read.
private final class CountingCommonDirectory: Sendable {
  private let calls = Mutex(0)
  let git: LiveGit

  init(runner: any ProcessRunner, root: URL) {
    git = LiveGit(runner: runner, repositoryRoot: root.path)
  }

  var count: Int { calls.withLock { $0 } }

  func read() async throws(GitError) -> String {
    calls.withLock { $0 += 1 }
    return try await git.commonDirectory()
  }
}

/// A repository in a real directory, reached through a symlinked alias the way a hook's `cwd` can
/// name a checkout under `/var` or `/tmp`.
private struct AliasedRepositories {
  let base: URL
  let real: URL
  let alias: URL
  let runner = LiveProcessRunner(baseEnvironment: TemporaryGitRepository.environment)

  init() throws {
    base = TestTemporaryDirectory.root
      .appending(
        path: "swiftgate-plan-lock-cache-\(UUID().uuidString)", directoryHint: .isDirectory
      )
      .resolvingSymlinksInPath()
    real = base.appending(path: "real", directoryHint: .isDirectory)
    alias = base.appending(path: "alias", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
  }

  func remove() { TestTemporaryDirectory.remove(base) }

  /// A repository with one commit at `real/<name>`.
  func repository(_ name: String) async throws -> URL {
    let root = real.appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("a\n".utf8).write(to: root.appending(path: "A.swift"))
    try await git(in: root, "init", "-q", "-b", "main")
    try await git(in: root, "config", "commit.gpgsign", "false")
    try await git(in: root, "add", "-A")
    try await git(in: root, "commit", "-q", "-m", "base")
    return root
  }

  func git(in directory: URL, _ arguments: String...) async throws {
    let output = try await runner.run(
      ProcessInvocation(
        executable: "git", arguments: arguments, workingDirectory: directory.path,
        timeout: .seconds(30)))
    guard output.status.isSuccess else {
      throw TestGitFailure(arguments: arguments, stderr: output.stderr.text)
    }
  }

  /// `path` spelled through the alias.
  func aliased(_ url: URL) -> URL {
    URL(
      filePath: alias.path + url.path.dropFirst(real.path.count), directoryHint: .isDirectory)
  }
}

@Suite("Plan-lock cache")
struct PlanLockCacheTests {
  static let session = "8f2c1d7e-5b4a-4c1e-9d3f-2a6b7c8d9e0f"

  @Test(
    "a second call in the same session and checkout answers the common dir without asking git — catches the guard spawning git on every design write"
  )
  func warmCacheSkipsGit() async throws {
    let repos = try AliasedRepositories()
    defer { repos.remove() }
    let root = repos.aliased(try await repos.repository("app"))
    let git = CountingCommonDirectory(runner: repos.runner, root: root)
    let expected = CanonicalPath.of(root.appending(path: ".git"))

    for _ in 0..<3 {
      let cache = try #require(PlanLockCache(worktreeRoot: root, sessionID: Self.session))
      let answer = try await cache.commonDirectory(environment: [:], read: git.read)
      #expect(answer == PlanLockCache.Answer(commonDirectory: expected, note: nil))
    }
    #expect(git.count == 1)
  }

  @Test(
    "a linked worktree removed and re-added from another repository at the same path is read fresh — catches a stale common dir judging a write against the wrong repository's locks"
  )
  func repointedWorktreeReadFresh() async throws {
    let repos = try AliasedRepositories()
    defer { repos.remove() }
    let first = try await repos.repository("first")
    let second = try await repos.repository("second")
    let linked = repos.real.appending(path: "first-task", directoryHint: .isDirectory)
    try await repos.git(in: first, "worktree", "add", "-q", "-b", "task", linked.path)
    let root = repos.aliased(linked)
    let git = CountingCommonDirectory(runner: repos.runner, root: root)
    let cache = try #require(PlanLockCache(worktreeRoot: root, sessionID: Self.session))

    #expect(
      try await cache.commonDirectory(environment: [:], read: git.read).commonDirectory
        == CanonicalPath.of(first.appending(path: ".git")))
    #expect(
      try await cache.commonDirectory(environment: [:], read: git.read).commonDirectory
        == CanonicalPath.of(first.appending(path: ".git")))
    #expect(git.count == 1)

    try await repos.git(in: first, "worktree", "remove", "--force", linked.path)
    try await repos.git(in: second, "worktree", "add", "-q", "-b", "task", linked.path)

    let repointed = try await cache.commonDirectory(environment: [:], read: git.read)
    #expect(repointed.commonDirectory == CanonicalPath.of(second.appending(path: ".git")))
    #expect(repointed.note == nil)
    #expect(git.count == 2)
  }

  @Test(
    "a repository initialised between a nested project and the repository it sat in is read fresh while the old one still exists — catches a cache keyed on the old common dir alone"
  )
  func nestedRepositoryReadFresh() async throws {
    let repos = try AliasedRepositories()
    defer { repos.remove() }
    let outer = try await repos.repository("outer")
    let project = outer.appending(path: "Apps/Counter", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let root = repos.aliased(project)
    let git = CountingCommonDirectory(runner: repos.runner, root: root)
    let cache = try #require(PlanLockCache(worktreeRoot: root, sessionID: Self.session))
    _ = try await cache.commonDirectory(environment: [:], read: git.read)
    _ = try await cache.commonDirectory(environment: [:], read: git.read)
    #expect(git.count == 1)

    let apps = outer.appending(path: "Apps", directoryHint: .isDirectory)
    try await repos.git(in: apps, "init", "-q", "-b", "main")

    let answer = try await cache.commonDirectory(environment: [:], read: git.read)
    #expect(answer.commonDirectory == CanonicalPath.of(apps.appending(path: ".git")))
    #expect(FileManager.default.fileExists(atPath: outer.appending(path: ".git").path))
    #expect(git.count == 2)
  }

  @Test(
    "a checkout moved to a new path is read fresh there — catches a cache carried along with the checkout answering the old location"
  )
  func movedCheckoutReadFresh() async throws {
    let repos = try AliasedRepositories()
    defer { repos.remove() }
    let original = try await repos.repository("app")
    let git = CountingCommonDirectory(runner: repos.runner, root: original)
    let cache = try #require(PlanLockCache(worktreeRoot: original, sessionID: Self.session))
    _ = try await cache.commonDirectory(environment: [:], read: git.read)
    _ = try await cache.commonDirectory(environment: [:], read: git.read)
    #expect(git.count == 1)

    let moved = repos.real.appending(path: "moved", directoryHint: .isDirectory)
    try FileManager.default.moveItem(at: original, to: moved)
    let movedGit = CountingCommonDirectory(runner: repos.runner, root: moved)
    let movedCache = try #require(PlanLockCache(worktreeRoot: moved, sessionID: Self.session))
    let answer = try await movedCache.commonDirectory(environment: [:], read: movedGit.read)

    #expect(answer.commonDirectory == CanonicalPath.of(moved.appending(path: ".git")))
    #expect(movedGit.count == 1)
  }

  @Test(
    "a corrupt cache file gives git's answer plus a note naming the file, then is rebuilt — catches a corrupt cache silently trusted or silently ignored"
  )
  func corruptCacheIsReadFreshWithNote() async throws {
    let repos = try AliasedRepositories()
    defer { repos.remove() }
    let root = try await repos.repository("app")
    let git = CountingCommonDirectory(runner: repos.runner, root: root)
    let cache = try #require(PlanLockCache(worktreeRoot: root, sessionID: Self.session))
    _ = try await cache.commonDirectory(environment: [:], read: git.read)
    try FileManager.default.createDirectory(
      at: cache.file.deletingLastPathComponent(), withIntermediateDirectories: true)
    for garbage in ["{not json", "{\"schemaVersion\": 1}", ""] {
      try Data(garbage.utf8).write(to: cache.file)

      let answer = try await cache.commonDirectory(environment: [:], read: git.read)
      #expect(answer.commonDirectory == CanonicalPath.of(root.appending(path: ".git")))
      #expect(answer.note?.contains(cache.file.path) == true, "\(garbage)")
    }
    #expect(git.count == 4)

    let rebuilt = try await cache.commonDirectory(environment: [:], read: git.read)
    #expect(rebuilt.note == nil)
    #expect(git.count == 4)
  }

  @Test(
    "an entry from an unknown schema is read around with a note, and a cache that can't be written says so on every call — catches a cache fault degrading silently"
  )
  func unknownSchemaAndUnwritableCacheAreNoted() async throws {
    let repos = try AliasedRepositories()
    defer { repos.remove() }
    let root = try await repos.repository("app")
    let git = CountingCommonDirectory(runner: repos.runner, root: root)
    let cache = try #require(PlanLockCache(worktreeRoot: root, sessionID: Self.session))
    _ = try await cache.commonDirectory(environment: [:], read: git.read)
    let written = try String(contentsOf: cache.file, encoding: .utf8)
    try Data(
      written.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2").utf8
    ).write(to: cache.file)

    let unknown = try await cache.commonDirectory(environment: [:], read: git.read)
    #expect(unknown.note?.contains("schemaVersion 2") == true, "\(unknown)")

    let state = cache.file.deletingLastPathComponent()
    try FileManager.default.removeItem(at: state)
    try Data("not a directory".utf8).write(to: state)
    for _ in 0..<2 {
      let unwritable = try await cache.commonDirectory(environment: [:], read: git.read)
      #expect(unwritable.commonDirectory == CanonicalPath.of(root.appending(path: ".git")))
      #expect(unwritable.note?.contains("couldn't be written") == true, "\(unwritable)")
    }
    #expect(git.count == 4)
  }

  @Test(
    "a session id that isn't one safe path component names no cache file — catches a session id escaping the hook-state directory"
  )
  func unsafeSessionIDsNameNoFile() throws {
    let root = URL(filePath: "/tmp/checkout", directoryHint: .isDirectory)
    for unsafe in ["", ".", "..", "a/b", "../escape", "../../x", "x\u{0}y", ".hidden", "a b"] {
      #expect(
        PlanLockCache(worktreeRoot: root, sessionID: unsafe) == nil, "\(unsafe.debugDescription)")
    }
    let cache = try #require(PlanLockCache(worktreeRoot: root, sessionID: Self.session))
    #expect(cache.file.lastPathComponent == "plan-lock-cache-\(Self.session).json")
    #expect(cache.file.deletingLastPathComponent().path == "/tmp/checkout/.harness/hook-state")
  }

  @Test(
    "session B neither reads nor touches session A's cache file — catches one session's cache answering for another"
  )
  func sessionsKeepSeparateFiles() async throws {
    let repos = try AliasedRepositories()
    defer { repos.remove() }
    let root = try await repos.repository("app")
    let git = CountingCommonDirectory(runner: repos.runner, root: root)
    let first = try #require(PlanLockCache(worktreeRoot: root, sessionID: "session-a"))
    let second = try #require(PlanLockCache(worktreeRoot: root, sessionID: "session-b"))
    _ = try await first.commonDirectory(environment: [:], read: git.read)
    try FileManager.default.createDirectory(
      at: first.file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{garbage".utf8).write(to: first.file)

    let answer = try await second.commonDirectory(environment: [:], read: git.read)
    #expect(answer.note == nil)
    #expect(git.count == 2)
    #expect(FileManager.default.fileExists(atPath: second.file.path))
    #expect(try String(contentsOf: first.file, encoding: .utf8) == "{garbage")
  }

  @Test(
    "a git failure is never cached, and git's GIT_DIR or GIT_COMMON_DIR override bypasses the cache — catches a failure or an overridden repository answered from a warm cache"
  )
  func failuresAndOverridesAreNeverCached() async throws {
    let repos = try AliasedRepositories()
    defer { repos.remove() }
    let root = try await repos.repository("app")
    let git = CountingCommonDirectory(runner: repos.runner, root: root)
    let cache = try #require(PlanLockCache(worktreeRoot: root, sessionID: Self.session))
    let failures = Mutex(0)
    let failing = { () async throws(GitError) -> String in
      failures.withLock { $0 += 1 }
      throw GitError.unparseableOutput(command: "rev-parse", detail: "empty --git-common-dir")
    }

    await #expect(throws: GitError.self) {
      _ = try await cache.commonDirectory(environment: [:], read: failing)
    }
    for variable in ["GIT_DIR", "GIT_COMMON_DIR"] {
      _ = try await cache.commonDirectory(environment: [variable: "/elsewhere"], read: git.read)
    }
    #expect(git.count == 2)
    _ = try await cache.commonDirectory(environment: [:], read: git.read)
    _ = try await cache.commonDirectory(environment: [:], read: git.read)
    #expect(git.count == 3)
    await #expect(throws: GitError.self) {
      _ = try await cache.commonDirectory(environment: ["GIT_DIR": "/elsewhere"], read: failing)
    }
    #expect(failures.withLock { $0 } == 2)
  }
}

import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("Git common dir and blobs")
struct GitCommonDirTests {
  @Test(
    "main checkout and a linked worktree resolve the same plan root — catches per-worktree plan state"
  )
  func linkedWorktreeSharesCommonDirectory() async throws {
    let repo = try await TemporaryGitRepository()
    defer { repo.remove() }
    try repo.write("A.swift", "a\n")
    _ = try await repo.commitAll("base")
    let linked = repo.root.deletingLastPathComponent()
      .appending(path: "\(repo.root.lastPathComponent)-linked", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: linked) }
    try await repo.git("worktree", "add", "-q", "-b", "task", linked.path)

    let main = try await repo.adapter.commonDirectory()
    let task = try await LiveGit(runner: repo.runner, repositoryRoot: linked.path)
      .commonDirectory()

    #expect(main == task)
    #expect(main == CanonicalPath.of(repo.root.appending(path: ".git")))
    #expect(
      try PlanStateLayout(commonDirectory: main).indexFile
        == PlanStateLayout(commonDirectory: task).indexFile)
  }

  @Test(
    "a root reached through a symlink resolves to the real common dir — catches /var vs /private/var mismatches the edit guard would miss"
  )
  func symlinkedRootIsCanonical() async throws {
    let repo = try await TemporaryGitRepository()
    defer { repo.remove() }
    try repo.write("A.swift", "a\n")
    _ = try await repo.commitAll("base")
    let alias = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-alias-\(UUID().uuidString)")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: repo.root)
    defer { try? FileManager.default.removeItem(at: alias) }
    let linked = repo.root.deletingLastPathComponent()
      .appending(path: "\(repo.root.lastPathComponent)-linked", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: linked) }
    try await repo.git("worktree", "add", "-q", "-b", "task", linked.path)

    let viaAlias = try await LiveGit(runner: repo.runner, repositoryRoot: alias.path)
      .commonDirectory()
    let viaLinked = try await LiveGit(runner: repo.runner, repositoryRoot: linked.path)
      .commonDirectory()

    #expect(viaAlias == viaLinked)
    #expect(!viaAlias.hasPrefix(alias.path))
    #expect(viaAlias == CanonicalPath.of(repo.root.appending(path: ".git")))
  }

  @Test(
    "git's relative common-dir output is made absolute against the adapter's root — catches a path relative to the gate's own cwd"
  )
  func relativeOutputMadeAbsolute() async throws {
    let repo = try await TemporaryGitRepository()
    defer { repo.remove() }
    try repo.write("examples/App/A.swift", "a\n")
    _ = try await repo.commitAll("base")
    let nested = LiveGit(
      runner: repo.runner, repositoryRoot: repo.root.appending(path: "examples/App").path)

    let expected = CanonicalPath.of(repo.root.appending(path: ".git"))
    #expect(try await repo.adapter.commonDirectory() == expected)
    #expect(try await nested.commonDirectory() == expected)
  }

  @Test(
    "a relative common-dir answer is joined to the root, not the process cwd — catches trusting git's cwd-relative output"
  )
  func relativeOutputJoinedToRoot() async throws {
    let runner = FakeProcessRunner { _ throws(ProcessRunnerError) in
      ProcessOutput(status: .exited(0), stdout: ".git\n")
    }
    let git = LiveGit(runner: runner, repositoryRoot: "/nonexistent-root/app")
    #expect(try await git.commonDirectory() == "/nonexistent-root/app/.git")
  }

  @Test(
    "an empty common-dir answer is a BLOCKED error — catches plan state rooted at the adapter's root itself"
  )
  func emptyOutput() async {
    let runner = FakeProcessRunner { _ throws(ProcessRunnerError) in
      ProcessOutput(status: .exited(0), stdout: "\n")
    }
    let git = LiveGit(runner: runner, repositoryRoot: "/repo")
    await #expect {
      _ = try await git.commonDirectory()
    } throws: { error in
      guard let error = error as? GitError, case .unparseableOutput = error else { return false }
      return error.verdict == .blocked
    }
  }

  @Test(
    "outside a git repository the common dir is a BLOCKED error — catches plan state silently rooted nowhere"
  )
  func outsideRepository() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-nogit-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let git = LiveGit(
      runner: LiveProcessRunner(
        baseEnvironment: TemporaryGitRepository.environment.merging(
          ["GIT_CEILING_DIRECTORIES": directory.deletingLastPathComponent().path]) { $1 }),
      repositoryRoot: directory.path)

    await #expect {
      _ = try await git.commonDirectory()
    } throws: { error in
      guard let error = error as? GitError, case .commandFailed = error else { return false }
      return error.verdict == .blocked
    }
  }

  @Test(
    "a blob is read by its id; an unknown id is nil — catches reading the working tree instead of the pinned design"
  )
  func blobByID() async throws {
    let repo = try await TemporaryGitRepository()
    defer { repo.remove() }
    try repo.write("design.md", "status: draft\n# Design\n")
    _ = try await repo.commitAll("base")
    let id = try await repo.git("rev-parse", "HEAD:design.md")
    try repo.write("design.md", "changed since\n")

    #expect(try await repo.adapter.blobContents(id) == "status: draft\n# Design\n")
    #expect(
      try await repo.adapter.blobContents(String(repeating: "0", count: id.count)) == nil)
  }

  @Test(
    "blob ids that aren't hex object names are rejected before git runs — catches ref and option injection",
    arguments: ["", "-p", "HEAD", "HEAD:design.md", "abc", "abcd\n0123"])
  func rejectsNonHexID(id: String) async {
    let runner = FakeProcessRunner { _ throws(ProcessRunnerError) in
      ProcessOutput(status: .exited(0))
    }
    let git = LiveGit(runner: runner, repositoryRoot: "/repo")
    await #expect(throws: GitError.invalidRef(id)) {
      _ = try await git.blobContents(id)
    }
    #expect(runner.invocations.isEmpty)
  }

  @Test(
    "the fake answers the common dir and blobs it was given, and fails like git — catches command tests passing on a fake that can't fail"
  )
  func fake() async throws {
    let git = FakeGit(commonDirectory: "/repo/.git", blobs: ["abcd1234": "body\n"])
    #expect(try await git.commonDirectory() == "/repo/.git")
    #expect(try await git.blobContents("abcd1234") == "body\n")
    #expect(try await git.blobContents("ffff0000") == nil)

    let failing = FakeGit(failure: .invalidRef("x"))
    await #expect(throws: GitError.invalidRef("x")) { _ = try await failing.commonDirectory() }
    await #expect(throws: GitError.invalidRef("x")) { _ = try await failing.blobContents("abcd") }
  }
}

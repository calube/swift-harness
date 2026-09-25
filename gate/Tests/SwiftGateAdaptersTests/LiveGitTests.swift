import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// A real git repository in a temporary directory, isolated from the user's and system git config.
struct TemporaryGitRepository {
  static let environment: [String: String] = [
    "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
    "HOME": FileManager.default.temporaryDirectory.path,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
  ]

  let root: URL
  let runner = LiveProcessRunner(baseEnvironment: Self.environment)

  var adapter: LiveGit { LiveGit(runner: runner, repositoryRoot: root.path) }

  init() async throws {
    root = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-git-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try await git("init", "-q", "-b", "main")
    try await git("config", "commit.gpgsign", "false")
  }

  func remove() { try? FileManager.default.removeItem(at: root) }

  @discardableResult
  func git(_ arguments: String...) async throws -> String {
    let output = try await runner.run(
      ProcessInvocation(
        executable: "git", arguments: arguments, workingDirectory: root.path,
        timeout: .seconds(30)))
    guard output.status.isSuccess else {
      throw TestGitFailure(arguments: arguments, stderr: output.stderr.text)
    }
    return output.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func write(_ path: String, _ content: String) throws {
    let url = root.appending(path: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(content.utf8).write(to: url)
  }

  func delete(_ path: String) throws {
    try FileManager.default.removeItem(at: root.appending(path: path))
  }

  func commitAll(_ message: String) async throws -> String {
    try await git("add", "-A")
    try await git("commit", "-q", "-m", message)
    return try await git("rev-parse", "HEAD")
  }
}

struct TestGitFailure: Error {
  let arguments: [String]
  let stderr: String
}

@Suite("LiveGit")
struct LiveGitTests {
  @Test(
    "changed files cover committed, staged, unstaged, untracked, deleted — catches skipped tests")
  func changedFiles() async throws {
    let repo = try await TemporaryGitRepository()
    defer { repo.remove() }
    try repo.write(".gitignore", "build/\n")
    try repo.write("Keep.swift", "keep\n")
    try repo.write("Staged.swift", "a\n")
    try repo.write("Unstaged.swift", "a\n")
    try repo.write("Deleted.swift", "a\n")
    let base = try await repo.commitAll("base")

    try repo.write("Committed Space ü.swift", "new\n")
    _ = try await repo.commitAll("after base")
    try repo.write("Staged.swift", "b\n")
    try await repo.git("add", "Staged.swift")
    try repo.write("Unstaged.swift", "b\n")
    try repo.delete("Deleted.swift")
    try repo.write("Sub/Untracked.swift", "u\n")
    try repo.write("build/Ignored.swift", "i\n")

    let changed = try await repo.adapter.changedFiles(since: base)
    #expect(
      changed == [
        "Committed Space ü.swift", "Deleted.swift", "Staged.swift", "Sub/Untracked.swift",
        "Unstaged.swift",
      ])
  }

  @Test("staged added lines are exact 1-based ranges — catches off-by-one line attribution")
  func stagedAddedLines() async throws {
    let repo = try await TemporaryGitRepository()
    defer { repo.remove() }
    try repo.write("A.swift", (1...10).map { "line \($0)" }.joined(separator: "\n") + "\n")
    try repo.write("Gone.swift", "x\ny\n")
    _ = try await repo.commitAll("base")

    var lines = (1...10).map { "line \($0)" }
    lines.insert("added after 2", at: 2)
    lines[5] = "changed 5"
    lines.append(contentsOf: ["tail 1", "tail 2"])
    try repo.write("A.swift", lines.joined(separator: "\n") + "\n")
    try repo.write("Gone.swift", "x\n")
    try repo.write("New.swift", "n1\nn2\nn3\n")
    try repo.write("we\"ird.swift", "q\n")
    try repo.write("Ünïcode.swift", "u\n")
    try repo.write("Plus.swift", "++ b/Fake.swift\n@@ -1 +90,9 @@\n")
    try await repo.git("add", "-A")
    try repo.write("A.swift", "unstaged rewrite\n")

    let added = try await repo.adapter.stagedAddedLines()
    #expect(
      added == [
        AddedLines(path: "A.swift", ranges: [3...3, 6...6, 12...13]),
        AddedLines(path: "New.swift", ranges: [1...3]),
        AddedLines(path: "Plus.swift", ranges: [1...2]),
        AddedLines(path: "we\"ird.swift", ranges: [1...1]),
        AddedLines(path: "Ünïcode.swift", ranges: [1...1]),
      ])
  }

  @Test(
    "staged contents are the index blob, not the working tree — catches pre-commit checking unstaged edits"
  )
  func stagedContents() async throws {
    let repo = try await TemporaryGitRepository()
    defer { repo.remove() }
    try repo.write("A.swift", "committed\n")
    try repo.write("Sub/Ü b.swift", "committed\n")
    _ = try await repo.commitAll("base")
    try repo.write("A.swift", "staged\n")
    try repo.write("Sub/Ü b.swift", "staged ü\n")
    try repo.write("-dash.swift", "staged dash\n")
    try await repo.git("add", "-A")
    try repo.write("A.swift", "unstaged\n")

    let contents = try await repo.adapter.stagedContents(
      of: ["A.swift", "Sub/Ü b.swift", "-dash.swift"])
    #expect(
      contents == [
        "A.swift": "staged\n", "Sub/Ü b.swift": "staged ü\n", "-dash.swift": "staged dash\n",
      ])
    await #expect(throws: GitError.self) {
      try await repo.adapter.stagedContents(of: ["NotStaged.swift"])
    }
  }

  @Test(
    "user diff config cannot change parsed output — catches noprefix/color/external breaking parsing"
  )
  func hostileDiffConfig() async throws {
    let repo = try await TemporaryGitRepository()
    defer { repo.remove() }
    try repo.write("A.swift", "a\n")
    _ = try await repo.commitAll("base")
    for (key, value) in [
      ("diff.noprefix", "true"), ("diff.mnemonicPrefix", "true"), ("color.ui", "always"),
      ("diff.external", "false"), ("diff.relative", "true"), ("status.relativePaths", "true"),
    ] {
      try await repo.git("config", key, value)
    }
    try repo.write("A.swift", "a\nb\n")
    try await repo.git("add", "A.swift")

    #expect(
      try await repo.adapter.stagedAddedLines() == [AddedLines(path: "A.swift", ranges: [2...2])])
  }

  @Test("content hash is git's blob hash and omits missing files — catches stale stop-hook skips")
  func contentHashes() async throws {
    let repo = try await TemporaryGitRepository()
    defer { repo.remove() }
    try repo.write("A.swift", "hello\n")
    try repo.write("B.swift", "hello!\n")
    let hashes = try await repo.adapter.contentHashes(of: ["A.swift", "B.swift", "Missing.swift"])
    #expect(hashes["A.swift"] == "ce013625030ba8dba906f756967f9e9ca394464a")
    #expect(hashes["B.swift"] != nil && hashes["B.swift"] != hashes["A.swift"])
    #expect(hashes.count == 2)
  }

  @Test("merge-base finds the fork point and nil for unrelated history — catches wrong diff base")
  func mergeBase() async throws {
    let repo = try await TemporaryGitRepository()
    defer { repo.remove() }
    try repo.write("A.swift", "a\n")
    let fork = try await repo.commitAll("fork")
    try await repo.git("switch", "-q", "-c", "feature")
    try repo.write("B.swift", "b\n")
    _ = try await repo.commitAll("feature work")
    try await repo.git("switch", "-q", "main")
    try repo.write("C.swift", "c\n")
    _ = try await repo.commitAll("main work")
    try await repo.git("switch", "-q", "--orphan", "island")
    try repo.write("D.swift", "d\n")
    _ = try await repo.commitAll("island")

    #expect(try await repo.adapter.mergeBase("main", "feature") == fork)
    #expect(try await repo.adapter.mergeBase("main", "island") == nil)
  }

  @Test(
    "a root inside the worktree reports its prefix — catches toplevel-relative paths matched against a nested project"
  )
  func workingDirectoryPrefix() async throws {
    let repo = try await TemporaryGitRepository()
    defer { repo.remove() }
    try repo.write("examples/App/A.swift", "a\n")
    _ = try await repo.commitAll("base")
    let nested = LiveGit(
      runner: repo.runner, repositoryRoot: repo.root.appending(path: "examples/App").path)

    #expect(try await nested.workingDirectoryPrefix() == "examples/App/")
    #expect(try await repo.adapter.workingDirectoryPrefix() == "")
  }

  @Test(
    "unknown ref is a BLOCKED error, not an empty change set — catches silently skipping all tests")
  func unknownRef() async throws {
    let repo = try await TemporaryGitRepository()
    defer { repo.remove() }
    try repo.write("A.swift", "a\n")
    _ = try await repo.commitAll("base")
    await #expect {
      _ = try await repo.adapter.changedFiles(since: "no-such-ref")
    } throws: { error in
      guard let error = error as? GitError, case .commandFailed = error else { return false }
      return error.verdict == .blocked
    }
  }

  @Test("refs starting with '-' are rejected before running git — catches option injection")
  func optionLikeRef() async {
    let runner = FakeProcessRunner { _ throws(ProcessRunnerError) in
      ProcessOutput(status: .exited(0))
    }
    let git = LiveGit(runner: runner, repositoryRoot: "/repo")
    await #expect(throws: GitError.invalidRef("--output=/tmp/x")) {
      _ = try await git.changedFiles(since: "--output=/tmp/x")
    }
    await #expect(throws: GitError.invalidRef("-p")) {
      _ = try await git.mergeBase("main", "-p")
    }
    #expect(runner.invocations.isEmpty)
  }
}

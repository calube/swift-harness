import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
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
    "changed files between 2 commits list committed changes only, never the working tree — catches a write-set check blaming a worker for uncommitted scratch files"
  )
  func changedFilesBetweenCommits() async throws {
    let repo = try await TemporaryGitRepository()
    defer { repo.remove() }
    try repo.write("Keep.swift", "keep\n")
    try repo.write("Deleted.swift", "a\n")
    let base = try await repo.commitAll("base")

    try repo.write("Sub/Added ü.swift", "new\n")
    try repo.delete("Deleted.swift")
    let tip = try await repo.commitAll("task work")
    try repo.write("Keep.swift", "uncommitted\n")
    try repo.write("Scratch.swift", "untracked\n")

    let changed = try await repo.adapter.changedFiles(from: base, to: tip)
    #expect(changed == ["Deleted.swift", "Sub/Added ü.swift"])
  }

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
    "staged contents of many files come from one git process — catches a spawn per file blowing the commit-hook latency"
  )
  func stagedContentsBatched() async throws {
    let repo = try await TemporaryGitRepository()
    defer { repo.remove() }
    let paths = (0..<20).map { "Sources/File\($0).swift" }
    for (index, path) in paths.enumerated() { try repo.write(path, "let v = \(index)\n") }
    try repo.write("Empty.swift", "")
    try await repo.git("add", "-A")
    let recorder = RecordingProcessRunner(base: repo.runner)
    let adapter = LiveGit(runner: recorder, repositoryRoot: repo.root.path)

    let contents = try await adapter.stagedContents(of: paths + ["Empty.swift"])

    #expect(contents.count == 21)
    #expect(contents["Sources/File7.swift"] == "let v = 7\n")
    #expect(contents["Empty.swift"] == "")
    #expect(recorder.invocations.count == 1)
    await #expect(throws: GitError.self) {
      try await adapter.stagedContents(of: ["Sources/File1.swift", "Missing.swift"])
    }
    await #expect(throws: GitError.self) {
      try await adapter.stagedContents(of: ["Line\nBreak.swift"])
    }
  }

  @Test(
    "contents at a ref are that commit's blobs in one git process, omitting paths absent there — catches impact comparing against the working tree or failing on an added file"
  )
  func contentsAtRef() async throws {
    let repo = try await TemporaryGitRepository()
    defer { repo.remove() }
    try repo.write("A.swift", "base a\n")
    try repo.write("Sub/Ü b.swift", "base ü\n")
    let base = try await repo.commitAll("base")
    try repo.write("A.swift", "head a\n")
    try repo.write("New.swift", "new\n")
    _ = try await repo.commitAll("head")
    try repo.write("A.swift", "working a\n")
    let recorder = RecordingProcessRunner(base: repo.runner)
    let adapter = LiveGit(runner: recorder, repositoryRoot: repo.root.path)

    let contents = try await adapter.contents(
      of: ["A.swift", "Sub/Ü b.swift", "New.swift"], at: base)

    #expect(contents == ["A.swift": "base a\n", "Sub/Ü b.swift": "base ü\n"])
    #expect(recorder.invocations.count == 1)
    await #expect(throws: GitError.invalidRef("-x")) {
      try await adapter.contents(of: ["A.swift"], at: "-x")
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

@Suite("LiveGit added lines since a ref")
struct LiveGitAddedSinceTests {
  @Test(
    "lines added since a ref cover committed, unstaged and untracked changes — catches diff coverage blind to work not yet committed"
  )
  func addedSince() async throws {
    let repository = try await TemporaryGitRepository()
    defer { repository.remove() }
    try repository.write("Core.swift", "a\nb\nc\n")
    try repository.write("Gone.swift", "x\n")
    let base = try await repository.commitAll("base")
    try repository.write("Core.swift", "a\nB\nc\nd\n")
    _ = try await repository.commitAll("committed edit")
    try repository.write("Core.swift", "a\nB\nc\nd\ne\n")
    try repository.write("New.swift", "1\n2\n")
    try repository.delete("Gone.swift")

    let added = try await repository.adapter.addedLines(since: base)

    #expect(
      added == [
        AddedLines(path: "Core.swift", ranges: [2...2, 4...5]),
        AddedLines(path: "New.swift", ranges: [1...2]),
      ])
  }

  @Test("a ref starting with a dash is rejected — catches a ref parsed as a git option")
  func rejectsOptionRef() async throws {
    let repository = try await TemporaryGitRepository()
    defer { repository.remove() }

    await #expect(throws: GitError.invalidRef("--output=/tmp/x")) {
      _ = try await repository.adapter.addedLines(since: "--output=/tmp/x")
    }
  }
}

/// Delegates to a real runner and records each invocation, for asserting process counts.
final class RecordingProcessRunner: ProcessRunner {
  private let base: any ProcessRunner
  private let recorded = Mutex<[ProcessInvocation]>([])

  init(base: any ProcessRunner) { self.base = base }

  var invocations: [ProcessInvocation] { recorded.withLock { $0 } }

  func run(_ invocation: ProcessInvocation) async throws(ProcessRunnerError) -> ProcessOutput {
    recorded.withLock { $0.append(invocation) }
    return try await base.run(invocation)
  }
}

@Suite("LiveGit unified diff")
struct LiveGitUnifiedDiffTests {
  @Test(
    "the review diff covers working-tree edits since the ref, relative to the project — catches reviewers reading a stale or repo-wide diff"
  )
  func unifiedDiff() async throws {
    let repo = try await TemporaryGitRepository()
    defer { repo.remove() }
    try repo.write("app/Sources/Core/A.swift", "let a = 1\n")
    try repo.write("other/B.swift", "let b = 1\n")
    let base = try await repo.commitAll("base")
    try repo.write("app/Sources/Core/A.swift", "let a = 2\n")
    try repo.write("other/B.swift", "let b = 2\n")

    let project = LiveGit(
      runner: repo.runner, repositoryRoot: repo.root.appending(path: "app").path)
    let diff = try await project.unifiedDiff(since: base)

    #expect(diff.contains("+++ b/Sources/Core/A.swift"))
    #expect(diff.contains("-let a = 1\n+let a = 2"))
    #expect(!diff.contains("B.swift"))
  }

  @Test(
    "the numbered review diff gives a changed line its line in the new file, not in the patch — catches reviewers citing diff.patch lines"
  )
  func numberedDiffCitesSourceLines() async throws {
    let repo = try await TemporaryGitRepository()
    defer { repo.remove() }
    let before = (1...80).map { "let v\($0) = \($0)" }
    try repo.write("Tests/CounterTests.swift", before.joined(separator: "\n") + "\n")
    let base = try await repo.commitAll("base")
    var after = before
    after.insert("let early = 0", at: 5)
    after[72] = "let changed = 73"
    try repo.write("Tests/CounterTests.swift", after.joined(separator: "\n") + "\n")

    let diff = try await LiveGit(runner: repo.runner, repositoryRoot: repo.root.path)
      .unifiedDiff(since: base)
    let patchLine = try #require(
      diff.split(separator: "\n").firstIndex { $0 == "+let changed = 73" })
    let numbered = try NumberedDiff.render(diff)

    #expect(patchLine + 1 != 73)
    #expect(numbered.split(separator: "\n").contains("    73 + let changed = 73"))
    #expect(numbered.split(separator: "\n").contains("     6 + let early = 0"))
  }
}

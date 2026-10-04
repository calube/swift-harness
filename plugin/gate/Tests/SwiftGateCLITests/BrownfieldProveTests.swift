import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

@testable import SwiftGateCLI

/// Runs a temp clone's tests the way a repository's runner would, reading the tree it is given:
/// `check <files>` runs the named test files, `check-all` every file under `tests/`. A test file
/// holding `needs new` passes only when `src/lib.txt` holds `new`; `crash` kills the run; anything
/// else passes.
private final class TreeReadingRunner: AreaCommandRunning {
  let requests = Mutex<[AreaCommandRequest]>([])

  func run(_ request: AreaCommandRequest) async -> AreaCommandOutcome {
    requests.withLock { $0.append(request) }
    let tree = URL(filePath: request.workingDirectory, directoryHint: .isDirectory)
    let selected: [String]
    if request.command == "check-all" {
      selected =
        ((try? FileManager.default.contentsOfDirectory(atPath: tree.appending(path: "tests").path))
        ?? []).sorted().map { "tests/\($0)" }
    } else {
      selected = request.command.dropFirst("check ".count).split(separator: " ").map {
        String($0.trimmingCharacters(in: CharacterSet(charactersIn: "'")))
      }
    }
    let library = (try? String(contentsOf: tree.appending(path: "src/lib.txt"), encoding: .utf8))
    var failed = false
    for path in selected {
      let body = (try? String(contentsOf: tree.appending(path: path), encoding: .utf8)) ?? ""
      if body.contains("crash") { return .crashed(signal: 6, tail: "\(path) aborted") }
      if body.contains("needs new") && library?.contains("new") != true { failed = true }
    }
    return failed ? .failed(exit: 1, tail: "1 failed", junit: nil) : .passed
  }

  var commands: [String] { requests.withLock { $0.map(\.command) } }
}

@Suite("brownfield prove")
struct BrownfieldProveTests {
  private static let environment: [String: String] = [
    "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
    "HOME": TestTemporaryDirectory.sharedHome.path, "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_AUTHOR_NAME": "Test",
    "GIT_AUTHOR_EMAIL": "test@example.com", "GIT_COMMITTER_NAME": "Test",
    "GIT_COMMITTER_EMAIL": "test@example.com",
  ]

  private struct Clone {
    let base: URL
    let root: URL
  }

  private static func git(_ arguments: String..., in directory: URL) async throws {
    let output = try await LiveProcessRunner(baseEnvironment: environment).run(
      ProcessInvocation(
        executable: "git", arguments: ["-c", "commit.gpgsign=false"] + arguments,
        workingDirectory: directory.path, timeout: .seconds(60)))
    guard output.status.isSuccess else {
      throw ProveTestFailure(detail: "git \(arguments): \(output.stderr.text)")
    }
  }

  private static func write(_ files: [String: String], in root: URL) throws {
    for (path, text) in files {
      let url = root.appending(path: path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(text.utf8).write(to: url)
    }
  }

  /// `main` holds `src/lib.txt` = `old`; the checked-out `task` branch changes it to `new` and
  /// commits `tests`.
  private static func clone(tests: [String: String]) async throws -> Clone {
    let base = TestTemporaryDirectory.root.appending(
      path: "swiftgate-brownfield-prove-\(UUID().uuidString)", directoryHint: .isDirectory
    )
    .resolvingSymlinksInPath()
    let root = base.appending(path: "repo", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try await git("init", "-q", "-b", "main", in: root)
    try write(["src/lib.txt": "old\n", "tests/existing.test": "always\n"], in: root)
    try await git("add", "-A", in: root)
    try await git("commit", "-q", "-m", "base", in: root)
    try await git("checkout", "-q", "-b", "task", in: root)
    try write(["src/lib.txt": "new\n"].merging(tests) { $1 }, in: root)
    try await git("add", "-A", in: root)
    try await git("commit", "-q", "-m", "task", in: root)
    return Clone(base: base, root: root)
  }

  private static func config(testFiles: String?) -> BrownfieldConfig {
    BrownfieldConfig(
      brownfield: BrownfieldSettings(
        discoveredAt: "0", sliceBudgetSeconds: 30, timeBudgetMinutes: 0, sensitive: []),
      areas: [
        BrownfieldArea(
          name: "web", root: ".", language: .javascript, kind: .node, test: "check-all",
          testFiles: testFiles, lint: nil, build: nil, e2e: nil, testGlobs: ["tests/**"],
          packs: [], xcode: nil)
      ],
      allow: [], buildPresets: [:])
  }

  private static func prove(
    _ clone: Clone, runner: TreeReadingRunner, testFiles: String?,
    proofs: ProveResultCollector = ProveResultCollector()
  ) async -> ChangedTestJudgement {
    let process = LiveProcessRunner(baseEnvironment: environment)
    return await BrownfieldProve.run(
      root: clone.root, base: "main", config: config(testFiles: testFiles),
      junitDirectory: clone.base.appending(path: "junit"), proofs: proofs,
      dependencies: BrownfieldProve.Dependencies(
        git: LiveGit(runner: process, repositoryRoot: clone.root.path),
        scratch: LiveScratchWorktrees(
          runner: process, repositoryRoot: clone.root.path,
          directory: clone.base.appending(path: "scratch")),
        runner: runner, deadline: .seconds(60)))
  }

  private static func gating(_ judgement: ChangedTestJudgement) -> [String] {
    judgement.findings.filter { $0.severity.failsGate }.map { "\($0.ruleID) \($0.file)" }.sorted()
  }

  @Test(
    "a changed test that passes with the source reverted is neutral.not-proven and 1 that fails there is proven — catches prove reading the head run, where both pass"
  )
  func passingWithSourceRevertedIsNotProven() async throws {
    let clone = try await Self.clone(tests: [
      "tests/guards.test": "needs new\n", "tests/idle.test": "always\n",
    ])
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let runner = TreeReadingRunner()

    let judgement = await Self.prove(clone, runner: runner, testFiles: "check {files}")

    #expect(Self.gating(judgement) == ["neutral.not-proven tests/idle.test"])
    #expect(judgement.verdict == .red)
    #expect(runner.commands.first == "check 'tests/guards.test' 'tests/idle.test'")
  }

  @Test(
    "a crash on 1 of 3 changed tests reruns each alone and marks only the crasher prove.crashed — catches siblings marked crashed"
  )
  func crashRerunsEachTestAlone() async throws {
    let clone = try await Self.clone(tests: [
      "tests/a.test": "needs new\n", "tests/b.test": "needs new\n", "tests/c.test": "crash\n",
    ])
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let runner = TreeReadingRunner()

    let judgement = await Self.prove(clone, runner: runner, testFiles: "check {files}")

    #expect(Self.gating(judgement) == ["prove.crashed tests/c.test"])
    #expect(
      runner.commands == [
        "check 'tests/a.test' 'tests/b.test' 'tests/c.test'", "check 'tests/a.test'",
        "check 'tests/b.test'", "check 'tests/c.test'",
      ])
  }

  @Test(
    "an area without test_files runs its whole test command once and says so — catches a silent whole run read as a per-test proof"
  )
  func wholeRunWithoutTestFiles() async throws {
    let clone = try await Self.clone(tests: ["tests/idle.test": "always\n"])
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let runner = TreeReadingRunner()

    let judgement = await Self.prove(clone, runner: runner, testFiles: nil)

    #expect(runner.commands == ["check-all"])
    #expect(Self.gating(judgement) == ["neutral.not-proven tests/idle.test"])
    #expect(
      judgement.findings.contains {
        $0.ruleID == ProofRules.summaryRuleID && $0.message.contains("whole test command")
      })
  }
}

extension BrownfieldProveTests {
  @Test(
    "each changed test prove ran is handed over with its outcome and the merge base it reverted to — catches a brownfield run whose proof table stays empty"
  )
  func handsOverEachProvedTest() async throws {
    let clone = try await Self.clone(tests: [
      "tests/guards.test": "needs new\n", "tests/idle.test": "always\n", "tests/c.test": "crash\n",
    ])
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let proofs = ProveResultCollector()

    _ = await Self.prove(
      clone, runner: TreeReadingRunner(), testFiles: "check {files}", proofs: proofs)

    let mergeBase = try await LiveGit(
      runner: LiveProcessRunner(baseEnvironment: Self.environment),
      repositoryRoot: clone.root.path
    ).revision("main")
    #expect(
      proofs.results.map { "\($0.target) \($0.test) \($0.outcome.rawValue)" }.sorted() == [
        "web tests/c.test crashed", "web tests/guards.test proven",
        "web tests/idle.test passes-reverted",
      ])
    #expect(proofs.results.allSatisfy { $0.proofBase == mergeBase && mergeBase != nil })
  }
}

private struct ProveTestFailure: Error {
  let detail: String
}

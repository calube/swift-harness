import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// `mutate` end to end on the `gate/Fixtures/mutate` package pair: real git, real scratch
/// worktrees, real `swift build` and `swift test`. The same change is judged twice, once with a
/// weak test suite and once with a strong one.
@Suite("mutate self-test", .serialized)
struct MutateSelfTests {
  private static let fixtures = Fixture.gateDirectory.appending(path: "Fixtures/mutate")
  private static let environment: [String: String?] = [
    "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
  ]

  /// A git repository holding `Scorer` at its base, then the change plus `tests` uncommitted.
  private struct Repository {
    let root: URL
    let scratch: URL
    let runner = LiveProcessRunner()

    init(tests: String) async throws {
      let temporary = FileManager.default.temporaryDirectory
        .appending(path: "swiftgate-mutate-self-\(UUID().uuidString)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
      // SwiftPM reports the temporary directory with its `/private` prefix, which Foundation's
      // symlink resolution drops; `realpath` keeps it, so both sides agree.
      guard let resolved = realpath(temporary.path, nil) else {
        throw MutateSelfTestFailure(detail: "realpath \(temporary.path)")
      }
      defer { free(resolved) }
      let parent = URL(filePath: String(cString: resolved), directoryHint: .isDirectory)
      root = parent.appending(path: "repo", directoryHint: .isDirectory)
      scratch = parent.appending(path: "scratch", directoryHint: .isDirectory)
      for directory in [root, scratch] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      }
      try FileManager.default.copyItem(
        at: MutateSelfTests.fixtures.appending(path: "Scorer"),
        to: root.appending(path: "Scorer"))
      try? FileManager.default.removeItem(at: root.appending(path: "Scorer/.build"))
      try Data(".build/\n".utf8).write(to: root.appending(path: ".gitignore"))
      try await git("init", "-q", "-b", "main")
      try await git("add", "-A")
      try await git("-c", "commit.gpgsign=false", "commit", "-q", "-m", "base")
      for (fixture, destination) in [
        ("change/Score.swift", "Scorer/Sources/ScoreCore/Score.swift"),
        ("\(tests)/ScoreTests.swift", "Scorer/Tests/ScoreCoreTests/ScoreTests.swift"),
      ] {
        let target = root.appending(path: destination)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(
          at: MutateSelfTests.fixtures.appending(path: fixture), to: target)
      }
    }

    func remove() { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

    func git(_ arguments: String...) async throws {
      let output = try await runner.run(
        ProcessInvocation(
          executable: "git", arguments: arguments,
          environmentOverlay: MutateSelfTests.environment, workingDirectory: root.path,
          timeout: .seconds(30)))
      guard output.status.isSuccess else {
        throw MutateSelfTestFailure(detail: "git \(arguments): \(output.stderr.text)")
      }
    }

    func mutate() async throws -> ChangedTestJudgement {
      let gitRunner = LiveProcessRunner(baseEnvironment: Self.gitEnvironment)
      let swiftPM = LiveSwiftPM(runner: runner, repositoryRoot: root.path)
      let graph = try ModuleGraph(packages: [try await swiftPM.describe(packageDirectory: "Scorer")]
      )
      let config = try Config(
        xcode: "26.2", appScheme: "Scorer", packages: ["Scorer"],
        simulator: SimulatorConfig(device: "iPhone 17", os: "26.2"))
      return await MutateCheck.run(
        MutateCheck.Environment(
          root: root, git: LiveGit(runner: gitRunner, repositoryRoot: root.path),
          scratch: LiveScratchWorktrees(
            runner: gitRunner, repositoryRoot: root.path, directory: scratch),
          toolchain: LiveMutationToolchain(runner: runner), workers: 3,
          timeout: MutantTimeout()),
        graph: graph, config: config, base: "main",
        context: GateRun.Context(runID: "r", directory: root.appending(path: ".harness/runs/r")))
    }

    static var gitEnvironment: [String: String] {
      var environment = ProcessInfo.processInfo.environment
      for (key, value) in MutateSelfTests.environment { environment[key] = value }
      return environment
    }
  }

  @Test(
    "a weak test suite leaves mutants of the change alive, which is RED at their lines — catches mutate passing tests that pin nothing",
    .timeLimit(.minutes(5))
  )
  func weakSuiteIsRed() async throws {
    let repository = try await Repository(tests: "weak")
    defer { repository.remove() }

    let judgement = try await repository.mutate()

    #expect(judgement.verdict == .red)
    let survived = judgement.findings.filter { $0.ruleID == MutationRules.survivedRuleID }
    #expect(!survived.isEmpty)
    #expect(survived.allSatisfy { $0.file == "Scorer/Sources/ScoreCore/Score.swift" })
    #expect(
      survived.contains { $0.line == 5 && $0.message.contains("relational-boundary") })
  }

  @Test(
    "a strong test suite kills every mutant of the change, which is GREEN — catches mutate failing tests that do pin the behavior",
    .timeLimit(.minutes(5))
  )
  func strongSuiteIsGreen() async throws {
    let repository = try await Repository(tests: "strong")
    defer { repository.remove() }

    let judgement = try await repository.mutate()

    let summary = judgement.findings.first { $0.ruleID == MutationRules.summaryRuleID }?.message
    #expect(judgement.verdict == .green, "\(judgement.findings.map(\.message))")
    #expect(summary?.contains("0 survived") == true)
    #expect(summary?.contains("kill rate 100%") == true)
    #expect(
      judgement.findings.filter { $0.ruleID == MutationRules.killedRuleID }.count == 9)
  }
}

private struct MutateSelfTestFailure: Error {
  let detail: String
}

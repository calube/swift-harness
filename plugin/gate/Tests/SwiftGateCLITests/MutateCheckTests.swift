import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// `mutate` over the sample GameEngine source with git, scratch trees and the toolchain faked.
@Suite("swiftgate mutate")
struct MutateCheckTests {
  private static let package = "examples/SampleApp/Packages/GameEngine"
  private static let source = "\(package)/Sources/GameEngine/GameEngine.swift"
  private static let testFile = "\(package)/Tests/GameEngineTests/GameEngineTests.swift"
  /// `guard next.outcome == .inProgress, next.board.indices.contains(cell), next.board[cell] == nil`
  private static let guardLine = 75

  private struct Setup {
    let root: URL

    init() throws {
      root = TestTemporaryDirectory.root
        .appending(path: "swiftgate-mutate-\(UUID().uuidString)", directoryHint: .isDirectory)
      for path in [MutateCheckTests.source, MutateCheckTests.testFile] {
        let destination = root.appending(path: path)
        try FileManager.default.createDirectory(
          at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(
          at: Fixture.harnessCheckout.appending(path: path), to: destination)
      }
    }

    func remove() { TestTemporaryDirectory.remove(root) }

    var context: GateRun.Context {
      GateRun.Context(runID: "r", directory: root.appending(path: ".harness/runs/r"))
    }

    func environment(
      _ added: [AddedLines], toolchain: FakeMutationToolchain, workers: Int? = 2,
      scratch: CopyingScratchWorktrees? = nil
    ) -> MutateCheck.Environment {
      MutateCheck.Environment(
        root: root,
        git: FakeGit(changed: added.map(\.path), mergeBase: "base", addedSince: added),
        scratch: scratch ?? CopyingScratchWorktrees(seed: root), toolchain: toolchain,
        workers: workers, cores: 18, timeout: MutantTimeout())
    }
  }

  private static func graph() throws -> ModuleGraph {
    try ModuleGraph(packages: [
      PackageManifest(
        describeJSON: Fixture.describe("GameEngine"), repositoryRoot: Fixture.repositoryRoot)
    ])
  }

  private static func config(maxMutants: Int = 30) throws -> Config {
    try Config(
      xcode: "26.2", appScheme: "SampleApp", packages: ["examples/SampleApp/Packages/*"],
      simulator: SimulatorConfig(device: "iPhone 17", os: "26.2"),
      mutation: MutationConfig(maxMutants: maxMutants))
  }

  /// Kills only mutants whose file contains `killed`; the unmutated file passes.
  private static func toolchain(killing killed: String) -> FakeMutationToolchain {
    FakeMutationToolchain(test: { root, _ in
      let text = (try? String(contentsOf: root.appending(path: source), encoding: .utf8)) ?? ""
      return text.contains(killed)
        ? (.failed(failingTests: ["GameEngineTests.GameEngineTests/humanMove()"]), .seconds(1))
        : (.passed(executed: 6), .seconds(1))
    })
  }

  @Test(
    "mutants on changed engine lines run the engine's T1 targets; survivors are RED at their line, kills are notes — catches a weak engine test passing ready"
  )
  func survivorsAndKills() async throws {
    let setup = try Setup()
    defer { setup.remove() }
    let toolchain = Self.toolchain(killing: "!(next.outcome == .inProgress)")
    let added = [AddedLines(path: Self.source, ranges: [Self.guardLine...Self.guardLine])]

    let judgement = await MutateCheck.run(
      setup.environment(added, toolchain: toolchain), graph: try Self.graph(),
      config: try Self.config(), base: "origin/main", context: setup.context)

    #expect(judgement.verdict == .red)
    let survived = judgement.findings.filter { $0.ruleID == MutationRules.survivedRuleID }
    #expect(survived.count == 2)
    #expect(survived.allSatisfy { $0.file == Self.source && $0.line == Self.guardLine })
    #expect(
      judgement.findings.filter { $0.ruleID == MutationRules.killedRuleID }.count == 1)
    let selection = try #require(toolchain.tests.first?.selection)
    #expect(selection.packagePath == Self.package)
    #expect(selection.targets.map(\.name) == ["GameEngineTests"])
    let summary = judgement.findings.first { $0.ruleID == MutationRules.summaryRuleID }
    #expect(summary?.message.contains("3 mutants: 1 killed, 2 survived") == true)
    #expect(summary?.message.contains("2 workers") == true)
  }

  @Test(
    "with no --jobs or max_workers the worker count follows the default cap, and each tree is seeded with the mutated packages' builds — catches one cold build per core, or workers never reusing the main build"
  )
  func defaultWorkersAndSeeds() async throws {
    let setup = try Setup()
    defer { setup.remove() }
    let toolchain = Self.toolchain(killing: "!(next.outcome == .inProgress)")
    let scratch = CopyingScratchWorktrees(seed: setup.root)
    let added = [AddedLines(path: Self.source, ranges: [Self.guardLine...Self.guardLine])]

    let judgement = await MutateCheck.run(
      setup.environment(added, toolchain: toolchain, workers: nil, scratch: scratch),
      graph: try Self.graph(), config: try Self.config(), base: "origin/main",
      context: setup.context)

    let summary = judgement.findings.first { $0.ruleID == MutationRules.summaryRuleID }
    // 3 mutants on 18 cores: ceil(3 / 2) = 2.
    #expect(summary?.message.contains("2 workers") == true)
    #expect(scratch.requests.count == 2)
    #expect(scratch.requests.allSatisfy { $0.seededBuildDirectories == [Self.package] })
  }

  @Test(
    "[mutation] max_workers bounds the workers when --jobs is absent — catches the configured cap ignored"
  )
  func configuredWorkers() async throws {
    let setup = try Setup()
    defer { setup.remove() }
    let toolchain = Self.toolchain(killing: "!(next.outcome == .inProgress)")
    let added = [AddedLines(path: Self.source, ranges: [Self.guardLine...Self.guardLine])]
    let config = try Config(
      xcode: "26.2", appScheme: "SampleApp", packages: ["examples/SampleApp/Packages/*"],
      simulator: SimulatorConfig(device: "iPhone 17", os: "26.2"),
      mutation: MutationConfig(maxMutants: 30, maxWorkers: 1))

    let judgement = await MutateCheck.run(
      setup.environment(added, toolchain: toolchain, workers: nil), graph: try Self.graph(),
      config: config, base: "origin/main", context: setup.context)

    let summary = judgement.findings.first { $0.ruleID == MutationRules.summaryRuleID }
    #expect(summary?.message.contains("1 worker") == true)
    #expect(summary?.message.contains("2 workers") == false)
  }

  @Test(
    "a change touching only tests has nothing to mutate and runs nothing — catches mutate mutating test code"
  )
  func testsOnly() async throws {
    let setup = try Setup()
    defer { setup.remove() }
    let toolchain = FakeMutationToolchain()

    let judgement = await MutateCheck.run(
      setup.environment([AddedLines(path: Self.testFile, ranges: [1...80])], toolchain: toolchain),
      graph: try Self.graph(), config: try Self.config(), base: "origin/main",
      context: setup.context)

    #expect(judgement.verdict == .green)
    #expect(toolchain.builds.isEmpty)
    #expect(judgement.findings.contains { $0.message.contains("no mutants") })
  }

  @Test(
    "beyond max_mutants the run is sampled, and a rerun of the same diff runs the same mutants — catches the cap being ignored or reruns judging different mutants"
  )
  func sampledAndRepeatable() async throws {
    let setup = try Setup()
    defer { setup.remove() }
    let added = [AddedLines(path: Self.source, ranges: [1...90])]
    func mutatedLines() async throws -> ([Int], String?) {
      let judgement = await MutateCheck.run(
        setup.environment(added, toolchain: Self.toolchain(killing: "\u{0}")),
        graph: try Self.graph(), config: try Self.config(maxMutants: 4), base: "origin/main",
        context: setup.context)
      return (
        judgement.findings.filter { $0.ruleID == MutationRules.survivedRuleID }.compactMap(\.line),
        judgement.findings.first { $0.ruleID == MutationRules.summaryRuleID }?.message
      )
    }

    let (first, summary) = try await mutatedLines()
    let (second, _) = try await mutatedLines()

    #expect(first.count == 4)
    #expect(first == second)
    #expect(summary?.contains("4 mutants sampled from") == true)
  }

  @Test(
    "check --tier ready reaches the mutate step, and skips it with a note while T1 is RED — catches ready omitting mutation, or spending scratch builds on a failing baseline"
  )
  func readyWiresMutate() async throws {
    let repository = try ProbeRepository()
    defer { repository.remove() }
    let swiftPM = try ProbeRepository.swiftPM(replaying: "pass")
    let git = FakeGit(changed: [], mergeBase: "base")
    let toolchain = FakeMutationToolchain()

    // The probe's empty test target makes its T1 RED.
    let parts = try await CheckRun.run(
      root: repository.root, tier: .ready, base: "origin/main", context: repository.context(),
      dependencies: CheckRun.Dependencies(
        root: repository.root, swiftPM: swiftPM, git: git, formatter: FakeSwiftFormatter(),
        simulator: .fake,
        changedTests: ChangedTestChecks.Environment(
          root: repository.root, git: git, swiftPM: swiftPM,
          scratch: FakeScratchWorktrees(root: repository.root), scratchSwiftPM: { _ in swiftPM }),
        mutation: MutateCheck.Environment(
          root: repository.root, git: git, scratch: FakeScratchWorktrees(root: repository.root),
          toolchain: toolchain, workers: 1, timeout: MutantTimeout())))

    #expect(parts.findings.contains { $0.message == "mutate not run: T1 is RED" })
    #expect(toolchain.builds.isEmpty)
  }

  @Test(
    "after a T1 that is not RED the mutate step runs and its verdict joins T1 — catches surviving mutants not failing ready"
  )
  func mutateJoinsT1() async throws {
    let green = try TierResult(tier: .t1, verdict: .green, durationMilliseconds: 5, testCounts: nil)
    let survivor = try Finding(
      ruleID: MutationRules.survivedRuleID, severity: .major, file: "F.swift", line: 3,
      message: "survived", failureScenario: nil)

    let result = try await CheckRun.mutate(after: green) {
      ChangedTestJudgement(findings: [survivor], blocked: false)
    }

    #expect(result.tier.verdict == .red)
    #expect(result.findings == [survivor])
  }
}

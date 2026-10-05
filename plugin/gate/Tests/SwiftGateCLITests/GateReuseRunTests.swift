import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

@testable import SwiftGateCLI

@Suite("a brownfield check reuses a GREEN run on identical inputs")
struct GateReuseRunTests {
  static let sourceHash = "0123456789abcdef"

  /// Runs `check merge` in the plan checkout with `key`, its body GREEN or RED; returns whether
  /// the body ran.
  static func gate(
    _ scenario: PlanBranchScenario, key: String?, verdict: Verdict = .green
  ) async throws -> Bool {
    let checkout = URL(filePath: scenario.checkout, directoryHint: .isDirectory)
    let ran = Mutex(false)
    do {
      try await GateRun.execute(
        root: checkout, format: .json, command: "check merge",
        git: LiveGit(runner: scenario.runner, repositoryRoot: checkout.path), checkTier: .merge,
        events: nil, workingTree: LiveWorkingTree(runner: scenario.runner, root: checkout),
        reuseKey: key
      ) { _ in
        ran.withLock { $0 = true }
        return GateRunParts(tiers: [
          try TierResult(tier: .t1, verdict: verdict, durationMilliseconds: 1, testCounts: nil)
        ])
      }
    } catch is ExitCode {}
    return ran.withLock { $0 }
  }

  static func history(_ scenario: PlanBranchScenario) throws -> [RunHistoryRecord] {
    try RunStore(worktreeRoot: URL(filePath: scenario.checkout, directoryHint: .isDirectory))
      .readHistory().records
  }

  @Test(
    "a second check with the same key prints the first run and records nothing new, and a new key runs — catches a merge gate re-run on an unchanged commit"
  )
  func sameKeyIsReused() async throws {
    let scenario = try await PlanBranchScenario()
    defer { scenario.remove() }

    #expect(try await Self.gate(scenario, key: "k1"))
    #expect(try Self.history(scenario).map(\.reuseKey) == ["k1"])
    #expect(try await Self.gate(scenario, key: "k1") == false)
    #expect(try Self.history(scenario).count == 1)
    #expect(try await Self.gate(scenario, key: "k2"))
    #expect(try await Self.gate(scenario, key: nil))
    #expect(try Self.history(scenario).count == 3)
  }

  @Test(
    "a RED run is never reused — catches a gate that keeps answering RED after a flake"
  )
  func redIsNotReused() async throws {
    let scenario = try await PlanBranchScenario()
    defer { scenario.remove() }

    #expect(try await Self.gate(scenario, key: "k1", verdict: .red))
    #expect(try await Self.gate(scenario, key: "k1"))
  }

  @Test(
    "the reader keys a clean checkout by tree, merge base, binary and the clone's config, and gives no key for a dirty tree or an unnamed binary — catches a reuse across an edit or a config change"
  )
  func readerKeysOnlyKnownInputs() async throws {
    let scenario = try await PlanBranchScenario()
    defer { scenario.remove() }
    let checkout = URL(filePath: scenario.checkout, directoryHint: .isDirectory)
    func key(sourceHash: String? = Self.sourceHash) async throws -> String? {
      let reader = try #require(
        await BrownfieldGateReuseReader.live(
          root: checkout, runner: scenario.runner, sourceHash: sourceHash))
      return await reader.inputs(tier: .merge, base: "main").map(GateReuse.key)
    }

    let first = try #require(try await key())
    let inputs = try #require(
      await BrownfieldGateReuseReader.live(
        root: checkout, runner: scenario.runner, sourceHash: Self.sourceHash
      )?.inputs(tier: .merge, base: "main"))
    #expect(inputs.mergeBase == scenario.userTip)
    #expect(inputs.treeHash == (try await scenario.git("rev-parse", "HEAD^{tree}", in: scenario.checkout)))
    #expect(try await key() == first)
    #expect(try await key(sourceHash: nil) == nil)

    let config = URL(filePath: scenario.common).appending(path: "swift-harness/config.toml")
    try Data((PlanBranchScenario.config + "\n# edited\n").utf8).write(to: config)
    let edited = try #require(try await key())
    #expect(edited != first)

    try Data("UNSAVED = 1\n".utf8).write(to: URL(filePath: scenario.checkout + "/unsaved.py"))
    #expect(try await key() == nil)
  }
}

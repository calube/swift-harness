import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

@testable import SwiftGateCLI

/// What `prove` keeps for each changed test it ran, over the probe package in a temp repository
/// with `swift test` replayed from recorded runs.
@Suite("prove results recorded")
struct ProveResultRecordTests {
  private static let testFile = "XUnitProbe/Tests/ProbeTests/PassTests.swift"
  private static let sourceFile = "XUnitProbe/Sources/Probe/Probe.swift"
  private static let xcTest = "ProbeTests.PassXCTests/testDoubles"
  private static let swiftTest = "ProbeTests.PassSwiftTests/doubles"
  /// Where the recorded runs' console paths point.
  private static let recordedRoot = URL(
    filePath: "\(Fixture.repositoryRoot)/gate/Fixtures/swifttest")

  private struct FixedTree: WorkingTreeReading {
    func state() async throws(GitError) -> WorkingTreeState {
      WorkingTreeState(treeHash: "tree", dirty: false)
    }
  }

  /// Runs `prove` with the probe's changed test file on disk, `edit` applied to its text, and
  /// the reverted run replaying `reverted` in a scratch tree at `scratchRoot`.
  private static func prove(
    reverted: String, scratchRoot: URL = recordedRoot, edit: (String) -> String = { $0 }
  ) async throws -> [ProvedTest] {
    let repository = try ProbeRepository()
    defer { repository.remove() }
    let text = try String(
      contentsOf: Fixture.gateDirectory.appending(
        path: "Fixtures/swifttest/XUnitProbe/Tests/ProbeTests/PassTests.swift"),
      encoding: .utf8)
    try repository.write(testFile, edit(text))
    let git = FakeGit(
      changed: [testFile, sourceFile], mergeBase: "base",
      addedSince: [AddedLines(path: testFile, ranges: [1...15])])
    let revertedSwiftPM = try ProbeRepository.swiftPM(replaying: reverted)
    let environment = ChangedTestChecks.Environment(
      root: repository.root, git: git, swiftPM: try ProbeRepository.swiftPM(replaying: "pass"),
      scratch: FakeScratchWorktrees(root: scratchRoot), scratchSwiftPM: { _ in revertedSwiftPM })
    let context = repository.context()
    _ = await ChangedTestChecks.prove(
      environment, graph: try ModuleGraph(packages: [try ProbeRepository.manifest()]),
      base: "origin/main", context: context)
    return context.proofs.results
  }

  @Test(
    "a test that fails with the source reverted is recorded proven at the merge base with the reverted run's file:line and kind — catches the location of the head run, or none, recorded"
  )
  func proven() async throws {
    let proofs = try await Self.prove(reverted: "reverted")

    #expect(
      proofs.first { $0.test == Self.xcTest }
        == ProvedTest(
          test: Self.xcTest, target: "ProbeTests", outcome: .proven, proofBase: "base",
          assertion: ProveAssertion(file: Self.testFile, line: 7, kind: .xctAssert)))
    #expect(
      proofs.first { $0.test == Self.swiftTest }
        == ProvedTest(
          test: Self.swiftTest, target: "ProbeTests", outcome: .proven, proofBase: "base",
          assertion: ProveAssertion(file: Self.testFile, line: 13, kind: .expect)))
    #expect(proofs.count == 2)
  }

  @Test(
    "a Swift Testing failure on a #require line records kind require, though its console line reads like #expect's — catches every Swift Testing failure recorded as expect"
  )
  func requireKind() async throws {
    let proofs = try await Self.prove(reverted: "reverted") {
      $0.replacingOccurrences(of: "#expect(double(3) == 6)", with: "try #require(double(3) == 6)")
    }

    #expect(proofs.first { $0.test == Self.swiftTest }?.assertion?.kind == .require)
  }

  @Test(
    "a test that passes with the source reverted is recorded passes-reverted with no assertion — catches a passing reverted run recorded as proof"
  )
  func passesReverted() async throws {
    let proofs = try await Self.prove(reverted: "pass")

    #expect(proofs.map(\.test).sorted() == [Self.swiftTest, Self.xcTest])
    #expect(proofs.allSatisfy { $0.outcome == .passesReverted && $0.assertion == nil })
    #expect(proofs.allSatisfy { $0.proofBase == "base" })
  }

  @Test(
    "a test that does not compile with the source reverted is recorded compile-only — catches a compile error recorded as proof"
  )
  func compileOnly() async throws {
    let proofs = try await Self.prove(reverted: "compile-only")

    #expect(proofs.count == 2)
    #expect(proofs.allSatisfy { $0.outcome == .compileOnly && $0.assertion == nil })
  }

  @Test(
    "a failure path outside the run's root drops the assertion and keeps the outcome, and no recorded string holds the path — catches an absolute path stored in telemetry"
  )
  func absolutePathDropped() async throws {
    let elsewhere = URL(filePath: "/elsewhere/scratch")
    let proofs = try await Self.prove(reverted: "reverted", scratchRoot: elsewhere)

    let xc = try #require(proofs.first { $0.test == Self.xcTest })
    #expect(xc.outcome == .proven)
    #expect(xc.assertion == nil)
    #expect(proofs.first { $0.test == Self.swiftTest }?.assertion?.file == Self.testFile)
    let encoded = String(
      decoding: try JSONEncoder().encode(proofs.map(ProveResultEvent.init)), as: UTF8.self)
    #expect(!encoded.contains(Fixture.repositoryRoot))
    #expect(!encoded.contains("\"/"))
  }

  @Test(
    "a gate run writes 1 prove.result per proof prove handed over, each pointing at its gate.run — catches proofs the record never writes"
  )
  func runRecordsProofs() async throws {
    let repository = try ProbeRepository()
    defer { repository.remove() }
    let log = MemoryEventLog()
    let handed = [
      ProvedTest(
        test: Self.xcTest, target: "ProbeTests", outcome: .proven, proofBase: "base",
        assertion: ProveAssertion(file: Self.testFile, line: 7, kind: .xctAssert)),
      ProvedTest(
        test: Self.swiftTest, target: "ProbeTests", outcome: .passesReverted, proofBase: "base",
        assertion: nil),
    ]

    try await GateRun.execute(
      root: repository.root, format: .json, command: "check push",
      git: FakeGit(changed: [], mergeBase: "base", revisions: ["HEAD": "abc"]),
      checkTier: .push, events: log, workingTree: FixedTree()
    ) { context in
      context.proofs.record(handed)
      return GateRunParts(
        tiers: [
          try TierResult(tier: .t1, verdict: .green, durationMilliseconds: 1, testCounts: nil)
        ])
    }

    let run = try #require(log.events.first { $0.kind == .gateRun })
    let proofs = log.events.filter { $0.kind == .proveResult }
    #expect(proofs.map(\.payload) == handed.map { .proveResult(ProveResultEvent($0)) })
    #expect(proofs.allSatisfy { $0.parentID == run.eventID && $0.runID == run.runID })
  }

  @Test(
    "2 steps timed in parallel carry overlapping start offsets from the gate's start — catches steps stamped end to end, or not at all"
  )
  func parallelStepsOverlap() throws {
    let clock = Mutex(0)
    let collector = GateStepCollector(elapsed: { clock.withLock { $0 } })

    // prove runs from 0 to 100 ms; stress starts at 70 ms beside it and ends at 130 ms.
    clock.withLock { $0 = 100 }
    collector.record(.prove, tier: .t1, milliseconds: 100, verdict: .green)
    clock.withLock { $0 = 130 }
    collector.record(.stress, tier: .t1, milliseconds: 60, verdict: .green)

    let steps = collector.steps
    #expect(steps.map(\.startMs) == [0, 70])
    let first = try #require(steps.first?.startMs)
    let second = try #require(steps.last?.startMs)
    #expect(second < first + steps[0].milliseconds)
  }
}

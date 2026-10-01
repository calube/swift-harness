import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

@Suite("test results handed to the run's record")
struct TestResultHandoffTests {
  private struct FixedTree: WorkingTreeReading {
    func state() async throws(GitError) -> WorkingTreeState {
      WorkingTreeState(treeHash: "tree", dirty: false)
    }
  }

  @Test(
    "T1 hands every case of its captured reports to the run, beside a report that holds none — catches a host tier whose results never reach the record"
  )
  func hostTier() async throws {
    let repository = try ProbeRepository()
    defer { repository.remove() }
    let context = repository.context()

    let parts = try await TestCheck.run(
      root: repository.root, swiftPM: try ProbeRepository.swiftPM(replaying: "fail"),
      git: FakeGit(), affectedSince: nil, xcodebuild: ProbeRepository.matchingXcodebuild,
      context: context)

    let expected =
      try XUnitReport.parse(Fixture.data("SwiftTest/fail.xml")).count
      + XUnitReport.parse(Fixture.data("SwiftTest/fail-swift-testing.xml")).count
    #expect(context.tests.cases.count == expected)
    #expect(context.tests.cases.allSatisfy { $0.tier == .t1 && $0.target == "ProbeTests" })
    #expect(context.tests.cases.contains { $0.outcome == .failed })
    #expect(parts.tiers.first?.verdict == .red)
  }

  @Test(
    "T2 hands every case of its captured result bundle to the run with the T2 tier — catches a simulator tier whose results never reach the record"
  )
  func simulatorTier() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-handoff-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let graph = try ModuleGraph(
      packages: Fixture.samplePackages.map {
        try PackageManifest(
          describeJSON: Fixture.describe($0), repositoryRoot: Fixture.repositoryRoot)
      },
      apps: [], config: nil)
    let config = try Config(
      xcode: "26.2", appScheme: "SampleApp", packages: ["examples/SampleApp/Packages/*"],
      simulator: SimulatorConfig(device: "iPhone 17", os: "26.2"))
    let context = GateRun.Context(runID: "r", directory: root.appending(path: ".harness/runs/r"))

    _ = try await SimulatorTestCheck.t2(
      plan: TierPlan(allOf: graph, tier: .t2), graph: graph, config: config, root: root,
      dependencies: SimulatorTestCheck.Dependencies(
        makeDevices: { _ in FakeDevices() }, xcodebuild: FakeXcodebuild(status: .exited(0)),
        reader: FakeXcresultReader(scenario: "skip")),
      context: context)

    let bundle = try XcresultTestResults.parse(Fixture.data("Xcresult/skip.tests.json"))
    #expect(!bundle.testCases.isEmpty)
    let jobs = context.tests.cases.count / bundle.testCases.count
    #expect(jobs >= 1)
    #expect(context.tests.cases.count == jobs * bundle.testCases.count)
    #expect(context.tests.cases.allSatisfy { $0.tier == .t2 && $0.outcome == .skipped })
  }

  @Test(
    "a gate run records the cases its tiers handed over as test.result events pointing at its gate.run — catches a collector the record never reads"
  )
  func runRecordsHandedCases() async throws {
    let repository = try ProbeRepository()
    defer { repository.remove() }
    let log = MemoryEventLog()
    let handed = [
      TestCaseResult(
        test: "T.Suite/a", target: "T", tier: .t1, outcome: .passed, milliseconds: 2),
      TestCaseResult(
        test: "T.Suite/b", target: "T", tier: .t1, outcome: .skipped, milliseconds: nil),
    ]

    try await GateRun.execute(
      root: repository.root, format: .json, command: "check push",
      git: FakeGit(changed: [], mergeBase: "base", revisions: ["HEAD": "abc"]),
      checkTier: .push, events: log, workingTree: FixedTree()
    ) { context in
      context.tests.record(handed)
      return GateRunParts(
        tiers: [
          try TierResult(tier: .t1, verdict: .green, durationMilliseconds: 1, testCounts: nil)
        ])
    }

    let run = try #require(log.events.first { $0.kind == .gateRun })
    let results = log.events.filter { $0.kind == .testResult }
    #expect(results.map(\.payload) == handed.map { .testResult(TestResultEvent($0)) })
    #expect(results.allSatisfy { $0.parentID == run.eventID && $0.runID == run.runID })
  }
}

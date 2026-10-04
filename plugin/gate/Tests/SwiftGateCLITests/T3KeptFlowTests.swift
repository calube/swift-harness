import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// T3 turns each UI test mapped to a `[[flows]]` entry into a `qa.flow` record, from the result
/// bundles `gate/Fixtures/xcresult/capture-flow-video.sh` captured.
@Suite("T3 kept flows")
struct T3KeptFlowTests {
  private static func root() throws -> URL {
    let root = TestTemporaryDirectory.root
      .appending(path: "swiftgate-t3-flows-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(
      at: root.appending(path: "SampleApp.xcodeproj"), withIntermediateDirectories: true)
    return root
  }

  private static func config() throws -> Config {
    try Config(
      xcode: "26.2", appScheme: "SampleApp", packages: ["examples/SampleApp/Packages/*"],
      simulator: SimulatorConfig(device: "iPhone 17", os: "26.2"),
      pyramid: PyramidConfig(maxFlows: 10), flows: [Flow(name: "counter", reason: "critical")])
  }

  private static func run(_ scenario: String, root: URL) async throws -> (
    GateRunParts, GateRun.Context
  ) {
    let reader = FakeXcresultReader(keptFlows: scenario)
    let context = GateRun.Context(runID: "r", directory: root.appending(path: ".harness/runs/r"))
    let parts = try await SimulatorTestCheck.t3(
      config: try config(), root: root,
      dependencies: SimulatorTestCheck.Dependencies(
        makeDevices: { _ in FakeDevices() }, xcodebuild: FakeXcodebuild(), reader: reader,
        keptFlows: XCUITestFlowRecorder(reader: reader, agentDevice: FakeAgentDevice())),
      context: context)
    return (parts, context)
  }

  @Test(
    "a T3 run hands 1 xcuitest flow record per kept flow to the run, failing test included — catches kept flows that never reach qa.flow"
  )
  func recordsEachKeptFlow() async throws {
    let root = try Self.root()
    defer { TestTemporaryDirectory.remove(root) }

    let (_, context) = try await Self.run("fail", root: root)

    let flows = context.flows.flows
    #expect(flows.map(\.source) == [.xcuitest, .xcuitest])
    #expect(Set(flows.compactMap(\.flow)) == ["counter"])
    #expect(
      Set(flows.compactMap(\.test)) == [
        "CounterFlowUITests/testIncrementAndDecrementUpdateTheDisplayedCount()",
        "CounterFlowUITests/testFixedFactScenarioShowsItsFactWithoutNetwork()",
      ])
    let failing = try #require(flows.first { $0.test?.contains("Increment") == true })
    #expect(failing.steps.last?.ok == false)
  }

  @Test(
    "each kept flow with no screen recording adds a qa.video-unverified nit that leaves T3's verdict alone — catches a missing video failing the gate or passing unnoted"
  )
  func missingVideoIsANit() async throws {
    let root = try Self.root()
    defer { TestTemporaryDirectory.remove(root) }

    let (parts, _) = try await Self.run("no-video", root: root)

    let notes = parts.findings.filter { $0.ruleID == QAEvidenceGap.videoUnverifiedRuleID }
    #expect(notes.count == 2)
    #expect(notes.allSatisfy { $0.severity == .nit })
    #expect(
      notes.contains { $0.message.contains("testFixedFactScenarioShowsItsFactWithoutNetwork") })
    #expect(parts.tiers.first?.verdict == .green)
  }
}

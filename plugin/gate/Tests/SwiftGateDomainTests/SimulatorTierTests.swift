import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("xcodebuild test requests")
struct XcodebuildTestRequestTests {
  private func request(recording: SnapshotRecording = .never) -> XcodebuildTestRequest {
    XcodebuildTestRequest(
      container: .package(directory: "/w/Packages/CounterFeature"),
      scheme: "CounterFeature-Package", destinationUDID: "CLONE",
      derivedDataPath: "/w/.harness/derived-data/pkg", resultBundlePath: "/w/run/t2.xcresult",
      onlyTesting: ["CounterUISnapshotTests"], recording: recording)
  }

  @Test(
    "a gate run pins the clone, per-worktree DerivedData, macro skip and target filter, and never retries — catches runs on the shared simulator, the global DerivedData, or retries hiding flakes"
  )
  func arguments() {
    let arguments = request().arguments

    #expect(
      arguments == [
        "test", "-quiet", "-scheme", "CounterFeature-Package", "-destination", "id=CLONE",
        "-derivedDataPath", "/w/.harness/derived-data/pkg", "-resultBundlePath",
        "/w/run/t2.xcresult", "-skipMacroValidation", "-only-testing:CounterUISnapshotTests",
      ])
    #expect(Set(arguments).isDisjoint(with: XcodebuildTestRequest.refusedFlags))
    #expect(request().workingDirectory == "/w/Packages/CounterFeature")
  }

  @Test(
    "gate runs set snapshot recording to never for the runner and the build — catches a missing reference silently recorded and passing"
  )
  func neverRecords() {
    #expect(
      request().environment == [
        "SNAPSHOT_TESTING_RECORD": "never", "TEST_RUNNER_SNAPSHOT_TESTING_RECORD": "never",
      ])
    #expect(request(recording: .all).environment["TEST_RUNNER_SNAPSHOT_TESTING_RECORD"] == "all")
  }

  @Test("a project run names the project — catches the app scheme resolved in the wrong directory")
  func project() {
    let request = XcodebuildTestRequest(
      container: .project(path: "/w/App.xcodeproj"), scheme: "App", destinationUDID: "C",
      derivedDataPath: "/d", resultBundlePath: "/r")
    #expect(
      Array(request.arguments.prefix(4)) == ["test", "-quiet", "-project", "/w/App.xcodeproj"])
    #expect(request.workingDirectory == nil)
  }
}

@Suite("simulator jobs")
struct SimulatorJobTests {
  @Test(
    "T2 runs each package's scheme filtered to its simulator targets — catches T1 targets re-run on the simulator or the wrong scheme name"
  )
  func packageJobs() throws {
    let graph = try SampleGraph.graph()
    let jobs = SimulatorJob.packageJobs(plan: TierPlan(allOf: graph, tier: .t2), graph: graph)

    #expect(jobs.map(\.scheme) == ["CounterFeature-Package"])
    #expect(jobs.first?.onlyTesting == ["CounterUISnapshotTests"])
    #expect(jobs.first?.container == .package(path: "\(SampleGraph.packagesRoot)/CounterFeature"))
    #expect(
      jobs.first?.targets.map(\.path) == [
        "\(SampleGraph.packagesRoot)/CounterFeature/Tests/CounterUISnapshotTests"
      ])
  }

  @Test(
    "a single-product package's tests run under its product scheme — catches xcodebuild failing on a <Package>-Package scheme that does not exist"
  )
  func singleProductScheme() throws {
    let manifests = try SampleGraph.manifests()
    let engine = try #require(manifests.first { $0.name == "GameEngine" })
    let counter = try #require(manifests.first { $0.name == "CounterFeature" })

    #expect(PackageTestScheme.name(for: engine) == "GameEngine")
    #expect(PackageTestScheme.name(for: counter) == "CounterFeature-Package")
  }

  @Test(
    "the app container prefers a workspace and refuses to guess between projects — catches T3 building a project without its workspace's packages"
  )
  func appContainer() {
    #expect(
      AppContainer.choose(among: ["App.xcodeproj", "App.xcworkspace", "README.md"])
        == .success("App.xcworkspace"))
    #expect(
      AppContainer.choose(among: ["SampleApp.xcodeproj", "Packages"])
        == .success("SampleApp.xcodeproj"))
    #expect(
      AppContainer.choose(among: ["A.xcodeproj", "B.xcodeproj"])
        == .failure(.ambiguous(["A.xcodeproj", "B.xcodeproj"])))
    #expect(AppContainer.choose(among: ["Packages"]) == .failure(.none))
  }
}

@Suite("T3 flows")
struct FlowCoverageTests {
  private let flows = [
    Flow(name: "counter", reason: "r"), Flow(name: "checkout", reason: "r"),
  ]

  @Test(
    "a UI test maps to a flow by method or class name, case- and punctuation-insensitively — catches a declared flow's test reported as unmapped"
  )
  func maps() {
    #expect(
      FlowCoverage.flow(
        forTest: "CounterFlowUITests/testIncrementAndDecrementUpdateTheDisplayedCount()",
        flows: flows)?.name == "counter")
    #expect(
      FlowCoverage.flow(forTest: "SmokeUITests/testCheckout_paysWithCard()", flows: flows)?.name
        == "checkout")
    #expect(FlowCoverage.flow(forTest: "SmokeUITests/testSettingsOpen()", flows: flows) == nil)
  }

  @Test(
    "an unmapped UI test and an untested flow are RED — catches T3 growing past its closed list or a critical flow losing its only test"
  )
  func unmappedAndUntested() {
    let findings = FlowCoverage.findings(
      uiTests: ["CounterFlowUITests/testCount()", "SettingsUITests/testOpens()"], flows: flows,
      maxFlows: 10, file: "App.xcodeproj")

    #expect(
      findings.map(\.ruleID).sorted() == [
        FlowCoverage.untestedFlowRuleID, FlowCoverage.unmappedRuleID,
      ])
    #expect(findings.allSatisfy { $0.severity.failsGate })
    #expect(findings.contains { $0.message.contains("SettingsUITests/testOpens()") })
    #expect(findings.contains { $0.message.contains("checkout") })
  }

  @Test(
    "more UI tests than pyramid.max_flows is RED even when each maps — catches T3 bloating by adding tests under one flow"
  )
  func cap() {
    let findings = FlowCoverage.findings(
      uiTests: [
        "CounterFlowUITests/testA()", "CounterFlowUITests/testB()", "CheckoutUITests/testC()",
      ],
      flows: flows, maxFlows: 2, file: "App.xcodeproj")

    #expect(findings.map(\.ruleID) == [FlowCoverage.maxFlowsRuleID])
    #expect(findings.first?.severity.failsGate == true)
  }
}

@Suite("retry configuration")
struct TestRetryConfigurationTests {
  @Test(
    "a scheme or test plan that retries failures is RED; the sample scheme is clean — catches a flake passing on its second attempt"
  )
  func retries() throws {
    let scheme = try String(
      contentsOf: Fixture.harnessCheckout.appending(
        path: "examples/SampleApp/SampleApp.xcodeproj/xcshareddata/xcschemes/SampleApp.xcscheme"),
      encoding: .utf8)
    let retrying = scheme.replacingOccurrences(
      of: "<TestAction", with: "<TestAction\n      testRepetitionMode = \"retryOnFailure\"")
    let plan = #"{ "defaultOptions" : { "testRepetitionMode" : "retryOnFailure" } }"#

    #expect(
      TestRetryConfiguration.findings(in: [ConfigurationFile(path: "S.xcscheme", contents: scheme)])
        .isEmpty)
    let findings = TestRetryConfiguration.findings(in: [
      ConfigurationFile(path: "S.xcscheme", contents: retrying),
      ConfigurationFile(path: "P.xctestplan", contents: plan),
    ])
    #expect(findings.map(\.file) == ["S.xcscheme", "P.xctestplan"])
    #expect(findings.allSatisfy { $0.severity.failsGate })
  }
}

@Suite("snapshot recording")
struct SnapshotRecordingTests {
  private func evidence(recording: SnapshotRecording) throws -> SimulatorTestEvidence {
    SimulatorTestEvidence(
      tier: .t2,
      testTargets: [TestTargetReference(name: "CounterUISnapshotTests", path: "T")],
      succeeded: false, testResults: try Fixture.data("Xcresult/record.tests.json"),
      buildResults: try Fixture.data("Xcresult/record.build-results.json"),
      testSourceFiles: ["T/CounterViewSnapshotTests.swift", "T/XcresultProbeTests.swift"],
      repositoryRoot: "/SCRATCH", recording: recording)
  }

  @Test(
    "while recording, a record-mode issue counts as recorded but a real failure stays RED — catches record hiding a broken test, or record always failing"
  )
  func recordingRun() throws {
    let outcome = SimulatorTestEvidenceRules.evaluate(try evidence(recording: .all))

    #expect(outcome.verdict == .red)
    #expect(outcome.findings.count == 1)
    #expect(outcome.findings.first?.message.contains("testAddsWrong") == true)
    #expect(outcome.counts.passed == 1 && outcome.counts.failed == 1)
  }

  @Test(
    "outside recording, the same record-mode issue is a failure — catches a gate run that recorded a reference passing"
  )
  func gateRun() throws {
    let outcome = SimulatorTestEvidenceRules.evaluate(try evidence(recording: .never))

    #expect(outcome.counts.failed == 2)
    #expect(outcome.findings.count == 2)
  }

  @Test(
    "reference changes are reported as added, modified or removed; identical rewrites are not — catches record claiming every reference changed"
  )
  func changes() {
    let before = ["a.png": Data([1]), "b.png": Data([2]), "gone.png": Data([3])]
    let after = ["a.png": Data([1]), "b.png": Data([9]), "new.png": Data([4])]

    #expect(
      SnapshotReferences.changes(before: before, after: after) == [
        SnapshotReferences.Change(path: "b.png", kind: .modified),
        SnapshotReferences.Change(path: "gone.png", kind: .removed),
        SnapshotReferences.Change(path: "new.png", kind: .added),
      ])
  }
}

@Suite("harness gc")
struct HarnessGCTests {
  @Test(
    "only entries older than the cutoff are pruned — catches gc deleting a run or DerivedData still in use"
  )
  func expired() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let day: TimeInterval = 86_400
    let entries = [
      HarnessGC.Entry(path: "old", lastModified: now.addingTimeInterval(-8 * day)),
      HarnessGC.Entry(path: "edge", lastModified: now.addingTimeInterval(-7 * day + 1)),
      HarnessGC.Entry(path: "new", lastModified: now),
    ]

    #expect(HarnessGC.expired(entries, now: now, maxAgeDays: 7) == ["old"])
  }
}

@Suite("UI test bundles")
struct UITestBundleTests {
  @Test(
    "cases from a UI test bundle are marked as UI tests and unit bundle cases are not — catches T3 flow checks counting unit tests or missing XCUITests"
  )
  func marksUITests() throws {
    let ui = try XcresultTestResults.parse(Fixture.data("Xcresult/ui-pass.tests.json"))
    let unit = try XcresultTestResults.parse(Fixture.data("Xcresult/pass.tests.json"))

    #expect(
      ui.testCases.map(\.identifier) == [
        "CounterFlowUITests/testIncrementAndDecrementUpdateTheDisplayedCount()"
      ])
    #expect(ui.testCases.allSatisfy { $0.isUITest })
    #expect(!unit.testCases.isEmpty && unit.testCases.allSatisfy { !$0.isUITest })
  }
}

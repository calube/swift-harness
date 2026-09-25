import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// A throwaway root laid out like the sample app, driven with the sample packages' recorded
/// manifests and recorded result bundles.
private struct SimulatorRepository {
  let root: URL

  init(appContainer: String? = "SampleApp.xcodeproj") throws {
    root = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-sim-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    if let appContainer {
      try FileManager.default.createDirectory(
        at: root.appending(path: appContainer), withIntermediateDirectories: true)
    }
  }

  func remove() { try? FileManager.default.removeItem(at: root) }

  func context() -> GateRun.Context {
    GateRun.Context(runID: "r", directory: root.appending(path: ".harness/runs/r"))
  }

  func write(_ text: String, to path: String) throws {
    let url = root.appending(path: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }

  static func graph() throws -> ModuleGraph {
    try ModuleGraph(
      packages: Fixture.samplePackages.map {
        try PackageManifest(
          describeJSON: Fixture.describe($0), repositoryRoot: Fixture.repositoryRoot)
      },
      apps: [], config: nil)
  }

  static func config(flows: [String] = ["counter"], maxFlows: Int = 10) throws -> Config {
    try Config(
      xcode: "26.2", appScheme: "SampleApp", packages: ["examples/SampleApp/Packages/*"],
      simulator: SimulatorConfig(device: "iPhone 17", os: "26.2"),
      pyramid: PyramidConfig(maxFlows: maxFlows),
      flows: flows.map { Flow(name: $0, reason: "critical") })
  }
}

private func dependencies(
  _ xcodebuild: FakeXcodebuild, scenario: String, devices: FakeDevices = FakeDevices()
) -> SimulatorTestCheck.Dependencies {
  SimulatorTestCheck.Dependencies(
    makeDevices: { _ in devices }, xcodebuild: xcodebuild,
    reader: FakeXcresultReader(scenario: scenario))
}

private func report(_ parts: GateRunParts) throws -> RunReport {
  try RunReport(
    runID: "r", durationMilliseconds: 1, tiers: parts.tiers, findings: parts.findings,
    allowances: parts.allowances)
}

@Suite("swiftgate test --tier t2|t3")
struct SimulatorTestCheckTests {
  private func t2(
    _ repository: SimulatorRepository, _ xcodebuild: FakeXcodebuild, scenario: String,
    devices: FakeDevices = FakeDevices()
  ) async throws -> GateRunParts {
    let graph = try SimulatorRepository.graph()
    return try await SimulatorTestCheck.t2(
      plan: TierPlan(allOf: graph, tier: .t2), graph: graph,
      config: try SimulatorRepository.config(), root: repository.root,
      dependencies: dependencies(xcodebuild, scenario: scenario, devices: devices),
      context: repository.context())
  }

  @Test(
    "T2 runs the package's simulator targets on the clone with per-worktree DerivedData and recording off, and a passing bundle is GREEN — catches T2 on the shared simulator, global DerivedData, or silent recording"
  )
  func passes() async throws {
    let repository = try SimulatorRepository()
    defer { repository.remove() }
    let xcodebuild = FakeXcodebuild(status: .exited(0))

    let parts = try await t2(repository, xcodebuild, scenario: "pass")

    let request = try #require(xcodebuild.requests.first)
    #expect(xcodebuild.requests.count == 1)
    #expect(request.scheme == "CounterFeature-Package")
    #expect(request.destinationUDID == FakeDevices.device.udid)
    #expect(request.onlyTesting == ["CounterUISnapshotTests"])
    #expect(request.derivedDataPath.hasPrefix(repository.root.path + "/.harness/derived-data/"))
    #expect(request.resultBundlePath.hasPrefix(repository.root.path + "/.harness/runs/r/t2/"))
    #expect(request.recording == .never)
    #expect(
      request.container
        == .package(
          directory: repository.root.appending(
            path: "examples/SampleApp/Packages/CounterFeature", directoryHint: .isDirectory
          ).path))
    #expect(try report(parts).verdict == .green)
    #expect(parts.tiers.map(\.tier) == [.t2])
  }

  @Test(
    "a failing snapshot or assertion in the bundle is RED and names the test, whatever the exit code — catches T2 trusting xcodebuild's exit status"
  )
  func fails() async throws {
    let repository = try SimulatorRepository()
    defer { repository.remove() }

    let parts = try await t2(repository, FakeXcodebuild(status: .exited(0)), scenario: "fail")

    #expect(try report(parts).verdict == .red)
    #expect(parts.findings.contains { $0.message.contains("testAddsWrong") })
  }

  @Test(
    "no clone means BLOCKED and xcodebuild never runs — catches a missing simulator reported as failing code"
  )
  func noClone() async throws {
    let repository = try SimulatorRepository()
    defer { repository.remove() }
    let xcodebuild = FakeXcodebuild()

    let parts = try await t2(
      repository, xcodebuild, scenario: "pass",
      devices: FakeDevices(
        failure: .selection(
          .baseDeviceNotFound(device: "iPhone 17", os: "26.2", installedRuntimes: []))))

    #expect(xcodebuild.requests.isEmpty)
    #expect(try report(parts).verdict == .blocked)
    #expect(parts.findings.contains { $0.message.contains("iPhone 17") })
  }

  @Test(
    "a package scheme that retries failures makes T2 RED — catches a flake passing on its retry"
  )
  func retryScheme() async throws {
    let repository = try SimulatorRepository()
    defer { repository.remove() }
    let scheme =
      "examples/SampleApp/Packages/CounterFeature/.swiftpm/xcode/xcshareddata/xcschemes/"
      + "CounterFeature-Package.xcscheme"
    try repository.write(
      "<Scheme><TestAction testRepetitionMode = \"retryOnFailure\"></TestAction></Scheme>",
      to: scheme)

    let parts = try await t2(repository, FakeXcodebuild(), scenario: "pass")

    #expect(try report(parts).verdict == .red)
    #expect(
      parts.findings.contains { $0.ruleID == TestRetryConfiguration.ruleID && $0.file == scheme })
  }

  @Test(
    "T2 with nothing selected runs nothing and says so without failing — catches push blocking on a change no simulator test covers"
  )
  func nothingSelected() async throws {
    let repository = try SimulatorRepository()
    defer { repository.remove() }
    let graph = try SimulatorRepository.graph()
    let xcodebuild = FakeXcodebuild()

    let parts = try await SimulatorTestCheck.t2(
      plan: TierPlan(changedPaths: ["README.md"], graph: graph, tier: .t2), graph: graph,
      config: try SimulatorRepository.config(), root: repository.root,
      dependencies: dependencies(xcodebuild, scenario: "pass"), context: repository.context())

    #expect(xcodebuild.requests.isEmpty)
    #expect(parts.tiers.isEmpty)
    #expect(parts.findings.map(\.ruleID) == [SimulatorTestCheck.nothingSelectedRuleID])
  }

  @Test(
    "T3 runs the app scheme and a UI test mapped to a declared flow is GREEN — catches T3 rejecting a listed flow"
  )
  func t3Mapped() async throws {
    let repository = try SimulatorRepository()
    defer { repository.remove() }
    let xcodebuild = FakeXcodebuild()

    let parts = try await SimulatorTestCheck.t3(
      config: try SimulatorRepository.config(), root: repository.root,
      dependencies: dependencies(xcodebuild, scenario: "ui-pass"), context: repository.context())

    #expect(
      xcodebuild.requests.map(\.container)
        == [.project(path: repository.root.appending(path: "SampleApp.xcodeproj").path)])
    #expect(xcodebuild.requests.first?.scheme == "SampleApp")
    #expect(try report(parts).verdict == .green)
    #expect(parts.tiers.first?.testCounts?.passed == 1)
  }

  @Test(
    "a UI test outside [[flows]] makes T3 RED and the declared flow counts as untested — catches the closed flow list going unenforced"
  )
  func t3Unmapped() async throws {
    let repository = try SimulatorRepository()
    defer { repository.remove() }

    let unmapped = try await SimulatorTestCheck.t3(
      config: try SimulatorRepository.config(flows: ["checkout"]), root: repository.root,
      dependencies: dependencies(FakeXcodebuild(), scenario: "ui-pass"),
      context: repository.context())
    #expect(try report(unmapped).verdict == .red)
    #expect(
      Set(unmapped.findings.map(\.ruleID))
        == [FlowCoverage.unmappedRuleID, FlowCoverage.untestedFlowRuleID])

  }

  @Test(
    "T3 without declared flows runs nothing; without an app container it is RED — catches T3 building an arbitrary project or none"
  )
  func t3Preconditions() async throws {
    let noFlows = try SimulatorRepository()
    defer { noFlows.remove() }
    let xcodebuild = FakeXcodebuild()
    let skipped = try await SimulatorTestCheck.t3(
      config: try SimulatorRepository.config(flows: []), root: noFlows.root,
      dependencies: dependencies(xcodebuild, scenario: "ui-pass"), context: noFlows.context())
    #expect(xcodebuild.requests.isEmpty && skipped.tiers.isEmpty)

    let noApp = try SimulatorRepository(appContainer: nil)
    defer { noApp.remove() }
    let missing = try await SimulatorTestCheck.t3(
      config: try SimulatorRepository.config(), root: noApp.root,
      dependencies: dependencies(xcodebuild, scenario: "ui-pass"), context: noApp.context())
    #expect(try report(missing).verdict == .red)
    #expect(missing.findings.map(\.ruleID) == [SimulatorTestCheck.appContainerRuleID])
  }

  @Test(
    "--tier accepts t1, t2 and t3 and nothing else — catches an unknown tier running as t1"
  )
  func parsing() throws {
    let command = try #require(
      try SwiftGate.parseAsRoot(["test", "--tier", "t3"]) as? TestCommand)
    #expect(command.tier == .t3)
    #expect(throws: (any Error).self) { try SwiftGate.parseAsRoot(["test", "--tier", "t4"]) }
  }
}

@Suite("swiftgate snapshots record, gc")
struct MaintenanceCommandTests {
  @Test(
    "record refuses to run under an Xcode other than the pin — catches references re-rendered by another toolchain failing every pinned run"
  )
  func recordNeedsPinnedXcode() async throws {
    let repository = try ProbeRepository()
    defer { repository.remove() }
    let xcodebuild = FakeXcodebuild(versionOutput: "Xcode 26.4\nBuild version 17E192\n")

    let parts = try await SnapshotRecord.run(
      root: repository.root, swiftPM: try ProbeRepository.swiftPM(replaying: "pass"),
      packages: [],
      dependencies: SimulatorTestCheck.Dependencies(
        makeDevices: { _ in FakeDevices() }, xcodebuild: xcodebuild,
        reader: FakeXcresultReader(scenario: "record")),
      context: repository.context())

    #expect(xcodebuild.requests.isEmpty)
    #expect(parts.tiers.first?.verdict == .blocked)
    #expect(parts.findings.contains { $0.message.contains("26.2") })
  }

  @Test(
    "gc removes only expired entries under .harness and reports a failed orphan sweep — catches gc deleting fresh runs or hiding a sweep failure"
  )
  func gc() async throws {
    let repository = try ProbeRepository()
    defer { repository.remove() }
    let manager = FileManager.default
    for path in [".harness/derived-data/old", ".harness/runs/fresh"] {
      try manager.createDirectory(
        at: repository.root.appending(path: path), withIntermediateDirectories: true)
    }
    try manager.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1_000)],
      ofItemAtPath: repository.root.appending(path: ".harness/derived-data/old").path)

    let summary = await GCRun.run(root: repository.root, maxAgeDays: 7, now: Date()) {
      throw SimulatorCloneError.simctl(.unreadableOutput(command: "list", detail: "x"))
    }

    #expect(summary.removed == [".harness/derived-data/old"])
    #expect(manager.fileExists(atPath: repository.root.appending(path: ".harness/runs/fresh").path))
    #expect(summary.errors.count == 1)
  }
}

@Suite("repository root")
struct RepositoryRootTests {
  @Test(
    "a root under /tmp resolves to /private/tmp as swift package describe reports it — catches every graph load BLOCKED for repositories under /tmp or /var"
  )
  func canonicalRoot() {
    #expect(ScopeResolution.describeRoot(URL(filePath: "/tmp")) == "/private/tmp")
    #expect(ScopeResolution.describeRoot(URL(filePath: "/no/such/dir")) == "/no/such/dir")
  }
}

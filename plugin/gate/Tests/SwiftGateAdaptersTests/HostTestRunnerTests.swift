import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("HostTestRunner")
struct HostTestRunnerTests {
  private static let package = "gate/Fixtures/swifttest/XUnitProbe"
  private static let selection = HostTestSelection(
    packagePath: package,
    targets: [
      TestTargetReference(name: "ProbeTests", path: "\(package)/Tests/ProbeTests"),
      TestTargetReference(name: "EmptyTests", path: "\(package)/Tests/EmptyTests"),
    ])

  private func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-t1-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// Answers `swift test` by copying a recorded scenario's reports to the requested paths.
  private func replaying(_ scenario: String) -> FakeSwiftPM {
    FakeSwiftPM(serving: []) { request throws(SwiftPMError) in
      let st = LiveSwiftPM.swiftTestingReportPath(for: request.xunitOutputPath)
      for (name, destination) in [
        ("\(scenario).xml", request.xunitOutputPath), ("\(scenario)-swift-testing.xml", st),
      ] {
        if let data = try? Fixture.data("SwiftTest/\(name)") {
          try? data.write(to: URL(filePath: destination))
        }
      }
      let stdout = (try? Fixture.text("SwiftTest/\(scenario).stdout")) ?? ""
      return SwiftTestRun(
        output: ProcessOutput(status: .exited(1), stdout: stdout),
        xctestReportPath: request.xunitOutputPath, swiftTestingReportPath: st)
    }
  }

  @Test(
    "runs the package filtered to exactly its selected targets with coverage — catches T1 running unselected or T2 targets"
  )
  func request() async throws {
    let output = try scratch()
    defer { try? FileManager.default.removeItem(at: output) }
    let swiftPM = replaying("fail")

    _ = await HostTestRunner(swiftPM: swiftPM, root: Fixture.pluginRoot)
      .run([Self.selection], outputDirectory: output, readCoverage: false)

    let request = try #require(swiftPM.testRequests.first)
    #expect(request.packageDirectory == Self.package)
    #expect(request.filters == [#"^(ProbeTests|EmptyTests)\."#])
    #expect(request.parallel && request.codeCoverage)
    #expect(request.xunitOutputPath.hasPrefix(output.path))
  }

  @Test(
    "gathers both reports and the targets' sources so issues resolve to paths — catches a Swift Testing failure reported without its file"
  )
  func evidence() async throws {
    let output = try scratch()
    defer { try? FileManager.default.removeItem(at: output) }

    let results = await HostTestRunner(swiftPM: replaying("fail"), root: Fixture.pluginRoot)
      .run([Self.selection], outputDirectory: output, readCoverage: false)

    guard case .ran(let evidence, _) = try #require(results.first) else {
      Issue.record("expected a run, got \(results)")
      return
    }
    #expect(evidence.xctestReport != nil && evidence.swiftTestingReport != nil)
    #expect(evidence.testSourceFiles.contains("\(Self.package)/Tests/ProbeTests/FailTests.swift"))
    let outcome = HostTestEvidenceRules.evaluate(evidence)
    #expect(outcome.findings.contains { $0.file.hasSuffix("FailTests.swift") && $0.line == 13 })
    #expect(
      FileManager.default.fileExists(
        atPath: output.appending(path: "gate_Fixtures_swifttest_XUnitProbe.log").path))
  }

  @Test(
    "a report left by an earlier run is removed first — catches a stale green report standing in for a run that wrote none"
  )
  func staleReportsRemoved() async throws {
    let output = try scratch()
    defer { try? FileManager.default.removeItem(at: output) }
    let stale = output.appending(path: "gate_Fixtures_swifttest_XUnitProbe.xml")
    try Fixture.data("SwiftTest/pass.xml").write(to: stale)

    let results = await HostTestRunner(
      swiftPM: replaying("build-error"), root: Fixture.pluginRoot
    )
    .run([Self.selection], outputDirectory: output, readCoverage: false)

    guard case .ran(let evidence, _) = try #require(results.first) else {
      Issue.record("expected a run, got \(results)")
      return
    }
    #expect(evidence.xctestReport == nil)
  }

  @Test(
    "swift test failing to launch is a failed package, not evidence — catches a timeout judged as zero tests"
  )
  func launchFailure() async throws {
    let output = try scratch()
    defer { try? FileManager.default.removeItem(at: output) }
    let swiftPM = FakeSwiftPM(serving: []) { _ throws(SwiftPMError) in
      throw .process(.launchFailed(executable: "swift", reason: "gone"))
    }

    let results = await HostTestRunner(swiftPM: swiftPM, root: Fixture.pluginRoot)
      .run([Self.selection], outputDirectory: output, readCoverage: true)

    #expect(
      results == [
        .failed(
          packagePath: Self.package, .process(.launchFailed(executable: "swift", reason: "gone")))
      ])
  }

  @Test(
    "a real run of the probe's failing and crashing tests is RED at the failing line and the crash — catches evidence rules drifting from real swift test output"
  )
  func live() async throws {
    let output = try scratch()
    defer { try? FileManager.default.removeItem(at: output) }
    let swiftPM = LiveSwiftPM(
      runner: LiveProcessRunner(),
      repositoryRoot: Fixture.pluginRoot.resolvingSymlinksInPath().path)
    let selection = HostTestSelection(
      packagePath: Self.package, targets: [Self.selection.targets[0]])

    let results = await HostTestRunner(swiftPM: swiftPM, root: Fixture.pluginRoot)
      .run([selection], outputDirectory: output, readCoverage: true)

    guard case .ran(let evidence, _) = try #require(results.first) else {
      Issue.record("expected a run, got \(results)")
      return
    }
    let outcome = HostTestEvidenceRules.evaluate(evidence)
    #expect(outcome.verdict == .red)
    let located = Set(outcome.findings.map { "\($0.ruleID) \($0.file):\($0.line ?? 0)" })
    #expect(located.contains("t1.test-failed \(Self.package)/Tests/ProbeTests/FailTests.swift:7"))
    #expect(outcome.findings.contains { $0.ruleID == "t1.crashed" })
  }
}

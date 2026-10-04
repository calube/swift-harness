import Foundation
import SwiftGateDomain
import Testing

@Suite("sim verify app exits")
struct SimExitRuleTests {
  static let fixtures = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Fixtures/AgentDevice")
  static let reportName = "SampleApp-2026-10-04-151000.ips"
  static let reportPath = SimCrashReport.path(fileName: reportName)
  /// The captured run's device, bundle and start.
  static let udid = "346175A9-071A-41DA-9D2F-519510A282EA"
  static let startedAt = Date(timeIntervalSince1970: 1_791_144_484)
  static let capturedAt = Date(timeIntervalSince1970: 1_791_144_586.8264)

  static func fixture(_ path: String) throws -> Data {
    try Data(contentsOf: fixtures.appending(path: path))
  }

  static func crashReport() throws -> Data { try fixture("crash/\(reportName)") }

  /// The `data.state` of a captured `appstate --json`.
  static func capturedState(_ path: String) throws -> SimAppState {
    struct Envelope: Decodable {
      struct State: Decodable { let state: String }
      let data: State
    }
    let raw = try JSONDecoder().decode(Envelope.self, from: try fixture(path)).data.state
    return try #require(SimAppState(rawValue: raw))
  }

  static func session(
    udid: String = udid, bundleID: String = "com.example.SampleApp", startedAt: Date = startedAt
  ) -> SimSession {
    SimSession(
      agentDeviceVersion: "0.21.18", udid: udid, deviceType: "iPhone 17",
      runtime: "com.apple.CoreSimulator.SimRuntime.iOS-26-2", bundleID: bundleID, scenario: nil,
      headCommit: "0123456789abcdef0123456789abcdef01234567", startedAt: startedAt)
  }

  /// A step as `sim snap` records it: with its tree while the app runs, without once it doesn't.
  static func step(_ n: Int, _ state: SimAppState?) -> SimStep {
    SimStep(
      n: n, label: "step \(n)", assert: nil, screenshot: SimStep.screenshotPath(n: n),
      tree: state == .notRunning ? nil : SimStep.treePath(n: n), settled: true, elapsedMs: 900,
      appState: state)
  }

  static func evidence(
    _ steps: [SimStep], crashes: [String: SimEvidenceFile] = [:], session: SimSession = session()
  ) throws -> SimEvidence {
    let tree = try fixture("snapshot.stdout")
    var files: [String: SimEvidenceFile] = [:]
    for step in steps {
      files[step.screenshot] = .present(Data("png bytes".utf8))
      if let path = step.tree { files[path] = .present(tree) }
    }
    return SimEvidence(
      runID: "20261004T200803Z-169b3631", session: session, steps: steps, files: files,
      crashReports: crashes)
  }

  @Test(
    "the captured crash report reads as SampleApp on its device, crashed at its capture time with EXC_CRASH (SIGABRT) — catches a parser that misreads the body or the time"
  )
  func parsesCapturedReport() throws {
    let report = try SimCrashReport.parse(try Self.crashReport())
    #expect(report.processName == "SampleApp")
    #expect(report.bundleID == "com.example.SampleApp")
    #expect(report.processPath.contains("/CoreSimulator/Devices/\(Self.udid)/"))
    #expect(abs(report.captureTime.timeIntervalSince(Self.capturedAt)) < 0.001)
    #expect(report.exception == "EXC_CRASH (SIGABRT)")
    #expect(report.belongs(to: Self.session()))
  }

  @Test(
    "the captured post-crash appstate on a step is RED sim.app-exited naming the step and the copied report — catches a crash that still verifies GREEN"
  )
  func capturedCrashIsRed() throws {
    let running = try Self.capturedState("appstate.stdout")
    let exited = try Self.capturedState("crash/appstate-not-running.stdout")
    let evidence = try Self.evidence(
      [Self.step(1, running), Self.step(2, exited)],
      crashes: [Self.reportPath: .present(try Self.crashReport())])

    let report = SimVerifyReport.judged(
      evidence, checkoutHead: .commit(evidence.session.headCommit))

    #expect(report.verdict == .red)
    try #require(report.findings.map(\.rule) == [.appExited])
    let finding = report.findings[0]
    #expect(finding.step == 2)
    #expect(finding.path == Self.reportPath)
    #expect(finding.message.contains("step 002"))
    #expect(finding.message.contains(Self.reportPath))
    #expect(finding.message.contains("SIGABRT"))
  }

  @Test(
    "a run with the app in front at every step and no crash file passes, and the same run with the app gone at its last step does not — catches a rule that flags every run or none"
  )
  func appInFrontPasses() throws {
    let running = try Self.capturedState("appstate.stdout")
    let evidence = try Self.evidence([Self.step(1, running), Self.step(2, running)])
    #expect(SimExitRule.findings(evidence).isEmpty)
    #expect(
      SimVerifyReport.judged(evidence, checkoutHead: .commit(evidence.session.headCommit))
        .verdict == .green)
    let exited = try Self.evidence([Self.step(1, running), Self.step(2, .notRunning)])
    #expect(SimExitRule.findings(exited).map(\.rule) == [.appExited])
  }

  @Test(
    "a crash report from before startedAt, another device or another app is ignored, while the run's own is not — catches an earlier run's or another worktree's crash failing this run"
  )
  func foreignReportsIgnored() throws {
    let running = try Self.capturedState("appstate.stdout")
    let crashes: [String: SimEvidenceFile] = [Self.reportPath: .present(try Self.crashReport())]
    let own = try Self.evidence([Self.step(1, running)], crashes: crashes)
    #expect(SimExitRule.findings(own).map(\.rule) == [.appExited])
    for session in [
      Self.session(startedAt: Self.capturedAt.addingTimeInterval(1)),
      Self.session(udid: "00000000-0000-0000-0000-000000000000"),
      Self.session(bundleID: "com.example.Other"),
    ] {
      let evidence = try Self.evidence([Self.step(1, running)], crashes: crashes, session: session)
      #expect(SimExitRule.findings(evidence).isEmpty)
    }
  }

  @Test(
    "a crash report of the run's app that no step saw is still sim.app-exited, for the whole run — catches a crash after the last snap passing"
  )
  func unclaimedReport() throws {
    let running = try Self.capturedState("appstate.stdout")
    let evidence = try Self.evidence(
      [Self.step(1, running)], crashes: [Self.reportPath: .present(try Self.crashReport())])
    let findings = SimExitRule.findings(evidence)
    try #require(findings.map(\.rule) == [.appExited])
    #expect(findings[0].step == nil)
    #expect(findings[0].path == Self.reportPath)
  }

  @Test(
    "an exit with no crash report is sim.app-exited saying none was found, and later steps with the app still gone add nothing — catches a kill without a report passing, or 1 exit reported per step"
  )
  func exitWithoutReport() throws {
    let evidence = try Self.evidence([
      Self.step(1, .runningForeground), Self.step(2, .notRunning), Self.step(3, .notRunning),
    ])
    let findings = SimExitRule.findings(evidence)
    try #require(findings.map(\.rule) == [.appExited])
    #expect(findings[0].step == 2)
    #expect(findings[0].path == nil)
    #expect(findings[0].message.contains("no crash report"))
  }

  @Test(
    "a step log written before app states were recorded is not judged for exits, but an exit after such a step is — catches older runs turning RED, or a missing state hiding a later exit"
  )
  func unrecordedStatePasses() throws {
    let evidence = try Self.evidence([Self.step(1, nil), Self.step(2, nil)])
    #expect(SimExitRule.findings(evidence).isEmpty)
    let exited = try Self.evidence([Self.step(1, nil), Self.step(2, .notRunning)])
    #expect(SimExitRule.findings(exited).map(\.step) == [2])
  }

  @Test(
    "a file in sim/crashes that doesn't parse or can't be read is sim.evidence-missing naming it — catches a corrupt crash report hiding a crash"
  )
  func unreadableReport() throws {
    let evidence = try Self.evidence(
      [Self.step(1, .runningForeground)],
      crashes: [
        "crashes/a.ips": .present(try Self.fixture("crash/appstate-not-running.stdout")),
        "crashes/b.ips": .unreadable("permission denied"),
      ])
    let findings = SimExitRule.findings(evidence)
    try #require(findings.map(\.rule) == [.evidenceMissing, .evidenceMissing])
    #expect(findings.map(\.path) == ["crashes/a.ips", "crashes/b.ips"])
    #expect(findings[1].message.contains("permission denied"))
  }

  @Test(
    "a step with no tree whose app was running is sim.evidence-missing — catches a dropped tree hiding behind the exited-app exception"
  )
  func treelessRunningStep() throws {
    var step = Self.step(1, .runningForeground)
    step.tree = nil
    let evidence = try Self.evidence([step])
    let findings = SimEvidenceRules.findings(evidence, checkoutHead: nil)
    #expect(findings.map(\.rule) == [.evidenceMissing])
    #expect(findings.first?.step == 1)
  }
}

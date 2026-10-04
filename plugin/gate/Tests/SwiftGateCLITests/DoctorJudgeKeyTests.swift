import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// `doctor` with `[judge] backend = "jev"`: the key Jev needs must reach the session's
/// environment, and doctor never prints it.
@Suite("doctor: the judge backend's key")
struct DoctorJudgeKeyTests {
  private static let config = """
    schema = 1
    xcode = "26.2"
    app_scheme = "App"
    packages = ["Packages/*"]

    [simulator]
    device = "iPhone 17"
    os = "26.2"

    [judge]
    backend = "jev"
    send_to = "api.typesafe.ai"
    advisory_threshold = 0.6
    block_threshold = 0.9
    """
  private static let sentinel = "sentinel-doctor-jev-key-5e2a90"

  private static func doctor(environment: [String: String]) async throws -> (
    findings: [Finding], output: String
  ) {
    let repository = TestTemporaryDirectory.root
      .appending(path: "swiftgate-doctor-key-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { TestTemporaryDirectory.remove(repository) }
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    try Data(config.utf8).write(to: repository.appending(path: ".swiftgate.toml"))
    let runner = FakeProcessRunner { invocation throws(ProcessRunnerError) in
      throw .launchFailed(executable: invocation.executable, reason: "not on this test machine")
    }

    let parts = try await DoctorRun.run(
      root: repository, sessionID: nil, swiftPM: FakeSwiftPM(serving: []), runner: runner,
      environment: environment)

    let report = try RunReport(
      runID: "20261003T120000Z-0000abcd", durationMilliseconds: 0, tiers: parts.tiers,
      findings: parts.findings)
    let output =
      try ReportRenderer.render(report, format: .human)
      + ReportRenderer.render(report, format: .json)
    return (parts.findings, output)
  }

  @Test(
    "backend jev with no TYPESAFE_API_KEY is a major doctor.judge-key finding saying how a Claude Code session gets it, and a set key gives no finding and is never printed — catches a judge silently off for a missing key"
  )
  func missingKeyIsMajor() async throws {
    let missing = try await Self.doctor(environment: ["PATH": "/usr/bin"])
    let present = try await Self.doctor(environment: [JevPin.keyVariable: Self.sentinel])

    let finding = try #require(missing.findings.first { $0.ruleID == Doctor.judgeKeyRuleID })
    #expect(finding.severity == .major)
    #expect(finding.message.contains(JevPin.keyVariable))
    #expect(finding.message.contains("non-interactive"))
    #expect(finding.message.contains("settings.json"))
    #expect(!present.findings.contains { $0.ruleID == Doctor.judgeKeyRuleID })
    #expect(!present.output.contains(Self.sentinel))
    #expect(!missing.output.contains(Self.sentinel))
  }
}

import Foundation
import SwiftGateDomain
import Testing

@Suite("ReportRenderer")
struct ReportRendererTests {
  static func report(findings: [Finding], tiers: [TierResult] = []) throws -> RunReport {
    try RunReport(runID: "r1", durationMilliseconds: 1000, tiers: tiers, findings: findings)
  }

  static func finding(_ severity: Severity, _ index: Int, message: String? = nil) throws -> Finding
  {
    try Finding(
      ruleID: "rule.\(severity.rawValue)", severity: severity, file: "Sources/F\(index).swift",
      line: index + 1, message: message ?? "problem \(index)", failureScenario: nil)
  }

  @Test("human output matches the golden layout — catches drift in what hooks show Claude")
  func golden() throws {
    let output = ReportRenderer.human(try RunReportTests.sampleReport())
    let expected = [
      "swiftgate RED · run 20260924T101500Z-a1b2 · 4.2s",
      "  T0 RED 310ms",
      "  T1 GREEN 3.9s · 41 passed, 0 failed, 1 skipped",
      "findings: 2 (1 gating)",
      "  major    Packages/Core/Sources/Feed/FeedReducer.swift:42  determinism.date-now: "
        + "Date() in a Core module; inject a clock",
      "  nit      App/Sources/App.swift  comments.narration: Comment restates the code",
      "details: .harness/runs/20260924T101500Z-a1b2/",
    ].joined(separator: "\n")
    #expect(output == expected)
  }

  @Test(
    "500 findings render in at most 30 lines with an overflow count — catches hook context blow-up")
  func capsLines() throws {
    let findings = try (0..<500).map { try Self.finding(.minor, $0) }
    let lines = ReportRenderer.human(try Self.report(findings: findings))
      .split(separator: "\n", omittingEmptySubsequences: false)
    #expect(lines.count <= ReportRenderer.maxHumanLines)
    let shown = lines.filter { $0.hasPrefix("  minor") }.count
    #expect(shown > 0)
    #expect(lines.contains("  … \(500 - shown) more findings (0 gating) in details"))
    #expect(lines.last == "details: .harness/runs/r1/")
  }

  @Test("gating findings are shown before advisory ones — catches a blocker hidden by the cap")
  func gatingFirst() throws {
    let nits = try (0..<100).map { try Self.finding(.nit, $0) }
    let blocker = try Self.finding(.blocker, 100)
    let lines = ReportRenderer.human(try Self.report(findings: nits + [blocker]))
      .split(separator: "\n")
    try #require(lines.count > 2)
    #expect(lines[2].hasPrefix("  blocker  Sources/F100.swift:101  rule.blocker"))
  }

  @Test(
    "multi-line and huge messages stay on one bounded line — catches the cap bypassed by newlines")
  func singleLineMessages() throws {
    let findings = try (0..<40).map {
      try Self.finding(.major, $0, message: String(repeating: "line\n", count: 200))
    }
    let tiers = try Tier.allCases.map {
      try TierResult(tier: $0, verdict: .red, durationMilliseconds: 5, testCounts: nil)
    }
    let output = ReportRenderer.human(try Self.report(findings: findings, tiers: tiers))
    let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
    #expect(lines.count == ReportRenderer.maxHumanLines)
    #expect(lines.allSatisfy { $0.count <= 240 })
  }

  @Test("--json renders the full versioned report — catches JSON consumers getting the capped view")
  func jsonIsFullReport() throws {
    let findings = try (0..<500).map { try Self.finding(.minor, $0) }
    let report = try Self.report(findings: findings)
    let json = try ReportRenderer.render(report, format: .json)
    #expect(try RunReportJSON.decode(Data(json.utf8)) == report)
  }
}

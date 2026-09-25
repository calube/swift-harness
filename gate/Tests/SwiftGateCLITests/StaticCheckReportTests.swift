import SwiftGateDomain
import SwiftGateRules
import Testing

@testable import SwiftGateCLI

@Suite("StaticCheckReport")
struct StaticCheckReportTests {
  @Test(
    "waived findings are counted per rule in the report and keep it GREEN — catches allows vanishing from reports"
  )
  func countsAllowances() throws {
    let result = RuleRunResult(
      findings: [],
      allowances: [
        Allowance(ruleID: "safety.try-bang", path: "A.swift", line: 3, reason: "literal"),
        Allowance(ruleID: "safety.try-bang", path: "B.swift", line: 9, reason: "literal"),
        Allowance(ruleID: "det.date-init", path: "A.swift", line: 5, reason: "log stamp"),
      ])
    let report = try StaticCheckReport.make(
      runID: "r1", durationMilliseconds: 1, outcome: .checked(result))
    #expect(
      report.allowances == [
        try AllowanceCount(ruleID: "det.date-init", count: 1),
        try AllowanceCount(ruleID: "safety.try-bang", count: 2),
      ])
    #expect(report.verdict == .green)
  }
}

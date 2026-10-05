import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

@Suite("qa run: a table with only reason-only rows")
struct QARunReasonOnlyTests {
  /// The send-money trial's 6 tasks, all done, and its captured table: 12 reason-only rows.
  static func sendMoney(_ repo: QARepo) throws {
    let tasks = [
      "send-money-contract", "account-fake", "amount-rules", "contacts", "amount-confirm",
      "root-flow",
    ]
    try repo.plan([], tasks: Dictionary(uniqueKeysWithValues: tasks.map { ($0, .done) }))
    try Fixture.data("BrownfieldTrial/send-money-1-validation.json").write(
      to: repo.planDirectory.appending(path: ValidationTable.fileName))
  }

  @Test(
    "--final over the send-money trial's table, 12 reason-only rows and none with a check, is RED on 1 major qa.no-verifiable-row, counts the 12 in its message and report, and names no row — catches the trial's 0 of 0 rows verified read as GREEN"
  )
  func finalOverReasonOnlyTableIsRed() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try Self.sendMoney(repo)

    let report = await repo.run(QARunRun.Options(final: true))

    #expect(report.verdict == .red, "\(report.message)")
    #expect(report.rows.isEmpty)
    #expect(report.reasonOnly == 12)
    #expect(report.message.hasPrefix("0 of 12 rows verified (12 reason-only)"), "\(report.message)")
    #expect(report.message.contains("unverified"), "\(report.message)")
    #expect(report.findings.map(\.ruleID) == [QAReport.noVerifiableRowRuleID])
    #expect(report.findings.first?.severity == .major)
    #expect(report.findings.first?.message.contains("12") == true)
    let written = try QAReportJSON.decode(
      Data(
        contentsOf: try repo.runDirectory(report).appending(
          path: "\(QAReport.directory)/\(QAReport.fileName)")))
    #expect(written == report)
  }

  @Test(
    "while tasks still merge, --after over the same table keeps GREEN with the finding as a nit, and --at-base has none — catches a mid-build run stopped on a table it can't change yet"
  )
  func midBuildIsANit() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try Self.sendMoney(repo)

    let after = await repo.run(QARunRun.Options(after: "root-flow"))
    let atBase = await repo.run(QARunRun.Options(atBase: true))

    #expect(after.verdict == .green, "\(after.message)")
    #expect(after.findings.map(\.ruleID) == [QAReport.noVerifiableRowRuleID])
    #expect(after.findings.first?.severity == .nit)
    #expect(after.reasonOnly == 12)
    #expect(atBase.findings.isEmpty, "\(atBase.findings.map(\.message))")
  }
}

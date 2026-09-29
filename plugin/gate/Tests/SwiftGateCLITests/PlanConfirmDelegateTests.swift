import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

@Suite("plan confirm --by delegate stands in for the user")
struct PlanConfirmDelegateTests {
  typealias Confirm = PlanConfirmCommandTests

  /// plan.json's `approval` as written on disk, so the test reads the value a gate would.
  static func approvalOnDisk(_ scenario: PlanStateScenario) throws -> [String: Any] {
    let path = try scenario.layout.plan(Confirm.plan).planFile
    let data = try #require(FileManager.default.contents(atPath: path))
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    return try #require(object["approval"] as? [String: Any], "no approval in \(path)")
  }

  @Test(
    "--by delegate on a page that needs the user's confirm is recorded as delegate with the page sha after --by spec-quotes on it is refused — catches a delegate refused like spec-quotes, or recorded as the user"
  )
  func delegateConfirmsRequiredPage() async throws {
    let scenario = try PlanStateScenario()
    defer { scenario.harness.repository.remove() }
    let page = try Confirm.pageWithNoneSlice()
    _ = try await Confirm.claimed(scenario, page: page)
    let sha = SpecPageCheck.pageSha(Data(page.utf8))

    let quotes = await Confirm.confirm(
      scenario, by: "spec-quotes", spec: "recipient-postcode.spec.txt")
    #expect(quotes.status == .refused, "\(quotes.message)")
    #expect(quotes.rule == .needsUser)
    #expect(quotes.confirm == .required)
    #expect(try Confirm.planFile(scenario).specPageSource?.approval == nil)

    let report = await Confirm.confirm(
      scenario, by: "delegate", spec: "recipient-postcode.spec.txt")
    #expect(report.status == .confirmed, "\(report.message)")
    #expect(report.verdict.exitCode == 0)
    #expect(report.confirm == .required)
    #expect(report.by?.rawValue == "delegate")
    #expect(report.pageSha == sha)
    #expect(report.message.contains("by delegate"), "\(report.message)")

    let approval = try Self.approvalOnDisk(scenario)
    #expect(approval["by"] as? String == "delegate")
    #expect(approval["pageSha"] as? String == sha)
    #expect(try Confirm.planFile(scenario).specPageSource?.pageSha == sha)
    #expect(try Confirm.indexEntry(scenario)?.status == PlanStatus.approved.rawValue)

    let json = PlanConfirmRun.render(report, format: .json)
    let object = try #require(
      try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], "\(json)")
    #expect(object["by"] as? String == "delegate")
  }

  @Test(
    "a RED page is refused as plan-confirm.page-red under --by delegate and writes nothing — catches a delegate waving through a page the check fails"
  )
  func delegateRefusedOnRedPage() async throws {
    let scenario = try PlanStateScenario()
    defer { scenario.harness.repository.remove() }
    _ = try await Confirm.claimed(
      scenario, page: try Fixture.text("spec-page/shipping-address.page.txt"))
    let before = try Confirm.state(scenario)

    let report = await Confirm.confirm(scenario, by: "delegate", spec: "shipping-address.spec.txt")

    #expect(report.status == .refused, "\(report.message)")
    #expect(report.rule == .pageRed)
    #expect(report.verdict.exitCode == 1)
    #expect(try Confirm.state(scenario) == before)
  }

  @Test(
    "an unknown --by names delegate among the values it takes — catches the refusal hiding the delegated confirm from the session that needs it"
  )
  func unknownByNamesDelegate() async throws {
    let scenario = try PlanStateScenario()
    defer { scenario.harness.repository.remove() }
    _ = try await Confirm.claimed(
      scenario, page: try Fixture.text("spec-page/task-status.page.txt"))

    let report = await Confirm.confirm(scenario, by: "orchestrator", spec: "task-status.spec.txt")

    #expect(report.verdict.exitCode == 2)
    #expect(report.message.contains("delegate"), "\(report.message)")
  }
}

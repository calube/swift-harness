import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// The send-money trial's plan, linted as `plan import` lints it.
private enum SendMoneyPlan {
  static let contract = "send-money-contract"
  static let starter = [PlanLintValidation.AppArea(name: "InterviewStarter", root: ".")]

  static var text: String {
    get throws {
      try String(
        contentsOf: Fixture.directory.appending(path: "BrownfieldTrial/send-money-1-PLAN.md"),
        encoding: .utf8)
    }
  }

  static func findings(
    _ text: String, appAreas: [PlanLintValidation.AppArea] = starter,
    contractTask: String? = contract
  ) throws -> [Finding] {
    let plan = try LivePlanParser.parse(text)
    let validation = try #require(plan.validation)
    return try PlanLintValidation.findings(
      table: validation.table, requirements: plan.requirements.map(\.id),
      taskIDs: Set(plan.tasks.map(\.id)), hasIOSArea: !appAreas.isEmpty, file: "PLAN.md",
      rowLines: validation.rowLines, sectionLine: validation.headingLine,
      tasks: plan.tasks.map {
        PlanLintValidation.TaskWrites(id: $0.id, covers: $0.covers, writes: $0.writes)
      },
      appAreas: appAreas, contractTask: contractTask)
  }

  /// The requirement each finding of `ruleID` names first.
  static func requirements(_ findings: [Finding], _ ruleID: String) -> [String] {
    findings.filter { $0.ruleID == ruleID }.map { String($0.message.prefix { $0 != " " }) }
  }

  /// `text` with every reason-only row's Reason opened with `kind: `.
  static func tagging(_ text: String, _ kind: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
      line.hasPrefix("| req-") && line.contains(" | | | | | ")
        ? line.replacingOccurrences(of: " | | | | | ", with: " | | | | | \(kind): ")
        : String(line)
    }.joined(separator: "\n")
  }

  static let screenRequirements = [
    "req-contact-search", "req-contact-select", "req-continue-rule", "req-confirm-send",
    "req-send-success", "req-send-failure", "req-replace-screen",
  ]
}

@Suite("plan-lint validation: an app needs a flow row, and only an obstacle excuses a screen")
struct PlanLintAppFlowTests {
  @Test(
    "the send-money trial's plan, 4 tasks writing AppUI screens and every row reason-only naming unit tests, gets 1 major app-without-flow naming the InterviewStarter area at the Validation heading, and 1 screen-without-flow per requirement a non-contract screen task covers — catches a plan whose unit-test reasons excuse every screen from a flow"
  )
  func sendMoneyPlanNeedsAFlow() throws {
    let text = try SendMoneyPlan.text

    let findings = try SendMoneyPlan.findings(text)

    let app = findings.filter { $0.ruleID == PlanLintValidation.appWithoutFlowRuleID }
    #expect(app.count == 1, "\(findings.map(\.message))")
    #expect(app.first?.severity == .major)
    #expect(app.first?.message.contains("`InterviewStarter`") == true, "\(app.map(\.message))")
    #expect(
      app.first?.message.contains("Packages/AppFeature/Sources/AppUI/") == true,
      "\(app.map(\.message))")
    let heading = try #require(
      text.split(separator: "\n", omittingEmptySubsequences: false).firstIndex {
        $0 == "## Validation"
      })
    #expect(app.first?.line == heading + 1)
    #expect(
      SendMoneyPlan.requirements(findings, PlanLintValidation.screenWithoutFlowRuleID)
        == SendMoneyPlan.screenRequirements)
    #expect(findings.allSatisfy { $0.severity == .major })
  }

  @Test(
    "without the contract named, req-decimal-money, which only the contract's AccessibilityID stub ties to a screen, is a screen requirement too — catches a contract's stub screens counted as behaviour, or the contract exclusion applied to every task"
  )
  func contractStubsAreNoScreens() throws {
    let findings = try SendMoneyPlan.findings(try SendMoneyPlan.text, contractTask: nil)

    #expect(
      SendMoneyPlan.requirements(findings, PlanLintValidation.screenWithoutFlowRuleID)
        == ["req-contact-search", "req-contact-select", "req-continue-rule", "req-decimal-money"]
        + ["req-confirm-send", "req-send-success", "req-send-failure", "req-replace-screen"])
  }

  @Test(
    "reasons opened with an obstacle kind clear every screen-without-flow but not app-without-flow, and 1 flow row for a root-flow requirement clears that too — catches an app excused from flows by reasons alone, or a flow row that doesn't count for its area"
  )
  func obstaclesExcuseRequirementsNotTheApp() throws {
    let tagged = SendMoneyPlan.tagging(try SendMoneyPlan.text, "data")
    let flowRow =
      "| req-send-success | flow | `qa/send-success.flow.json` | root-flow | root-flow | |"
    let withFlow = tagged.split(separator: "\n", omittingEmptySubsequences: false).map {
      $0.hasPrefix("| req-send-success | | | | | ") ? flowRow : String($0)
    }.joined(separator: "\n")

    let taggedFindings = try SendMoneyPlan.findings(tagged)
    let flowed = try SendMoneyPlan.findings(withFlow)

    #expect(
      taggedFindings.map(\.ruleID) == [PlanLintValidation.appWithoutFlowRuleID],
      "\(taggedFindings.map(\.message))")
    #expect(withFlow.contains(flowRow + "\n"))
    #expect(flowed.isEmpty, "\(flowed.map(\.message))")
  }

  @Test(
    "a flow row only counts for the area its tasks write: with the app moved under ios/, the same plan's tasks write no screen there and nothing fires, and an area rooted where the screen tasks write still needs the flow — catches a flow row in 1 app read as covering another"
  )
  func flowCountsPerArea() throws {
    let text = try SendMoneyPlan.text
    let elsewhere = [PlanLintValidation.AppArea(name: "ios", root: "ios")]
    let packages = [
      PlanLintValidation.AppArea(name: "ios", root: "ios"),
      PlanLintValidation.AppArea(name: "Packages", root: "Packages"),
    ]

    #expect(try SendMoneyPlan.findings(text, appAreas: elsewhere).isEmpty)
    let findings = try SendMoneyPlan.findings(text, appAreas: packages)
    let app = findings.filter { $0.ruleID == PlanLintValidation.appWithoutFlowRuleID }
    #expect(app.count == 1, "\(findings.map(\.message))")
    #expect(app.first?.message.contains("`Packages`") == true, "\(app.map(\.message))")
  }

  @Test(
    "obstacle(of:) reads each kind with a colon and a detail, and nothing else: no unit-test claim, no bare kind, no other case or spacing — catches a reason that names tests read as an obstacle"
  )
  func obstacleKindsParse() {
    for kind in PlanLintValidation.obstacleKinds {
      #expect(PlanLintValidation.obstacle(of: "\(kind): the simulator lacks it") == kind)
      #expect(PlanLintValidation.obstacle(of: "  \(kind):the simulator lacks it") == kind)
      #expect(PlanLintValidation.obstacle(of: "\(kind):") == nil)
      #expect(PlanLintValidation.obstacle(of: "\(kind):   ") == nil)
      #expect(PlanLintValidation.obstacle(of: "\(kind.uppercased()): x") == nil)
      #expect(PlanLintValidation.obstacle(of: "\(kind) : x") == nil)
    }
    #expect(PlanLintValidation.obstacle(of: "AmountInputTests in amount-rules check it") == nil)
    #expect(PlanLintValidation.obstacle(of: "unit: the tests prove it") == nil)
    #expect(PlanLintValidation.obstacle(of: "") == nil)
  }
}

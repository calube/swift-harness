import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// The third send-money trial's plan, as `plan import` first refused it and as the orchestrator
/// then rewrote it to get past the refusal.
private enum SendMoneyPlan {
  static let contract = "send-money-contract"
  static let appAreas = [PlanLintValidation.AppArea(name: "InterviewStarter", root: ".")]
  static let untagged =
    "| req-existing-tests | | | | | the final gate runs every area's whole suite, APIClient and "
    + "LogClient included |"

  /// The plan the import read: `req-existing-tests` covered by the views task, whose screen it
  /// sits on, as the orchestrator's first edit left it.
  static var refused: String {
    get throws {
      var text = try Fixture.text("BrownfieldTrial/send-money-3-PLAN.md")
      for (old, new) in [
        (
          "- Covers: req-account-fake, req-existing-tests\n- Writes: Packages/APIClient/Package.swift",
          "- Covers: req-account-fake\n- Writes: Packages/APIClient/Package.swift"
        ),
        (
          ", req-send-failure\n- Writes: Packages/AppFeature/Sources/AppUI/SendMoneyView.swift",
          ", req-send-failure, req-existing-tests\n"
            + "- Writes: Packages/AppFeature/Sources/AppUI/SendMoneyView.swift"
        ),
      ] {
        let range = try #require(text.range(of: old), "`\(old)` not in the captured plan")
        text.replaceSubrange(range, with: new)
      }
      return text
    }
  }

  static func replacing(_ old: String, with new: String, in text: String) throws -> String {
    let range = try #require(text.range(of: old), "`\(old)` not in the plan")
    return text.replacingCharacters(in: range, with: new)
  }

  /// The screen-without-flow findings `plan import` gives `text`.
  static func screenFindings(_ text: String) throws -> [Finding] {
    let plan = try LivePlanParser.parse(text)
    let validation = try #require(plan.validation)
    return try PlanLintValidation.findings(
      table: validation.table, requirements: plan.requirements.map(\.id),
      taskIDs: Set(plan.tasks.map(\.id)), hasIOSArea: true, file: "PLAN.md",
      rowLines: validation.rowLines, sectionLine: validation.headingLine,
      tasks: plan.tasks.map {
        PlanLintValidation.TaskWrites(id: $0.id, covers: $0.covers, writes: $0.writes)
      },
      appAreas: appAreas, contractTask: contract,
      requirementTitles: Dictionary(
        plan.requirements.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
    ).filter { $0.ruleID == PlanLintValidation.screenWithoutFlowRuleID }
  }
}

@Suite("plan-lint validation: a gate tier's suites prove an existing-tests requirement")
struct PlanLintGateReasonTests {
  @Test(
    "the send-money-3 plan with req-existing-tests on the views task it belongs to imports once its reason-only row opens with gate: and names the final gate, and is refused with the same reason untagged — catches the trial's orchestrator moving the requirement onto the done contract to get past the screen rule"
  )
  func gateReasonExcusesExistingTests() throws {
    let refused = try SendMoneyPlan.refused
    let untagged = try SendMoneyPlan.screenFindings(refused)
    #expect(untagged.map { String($0.message.prefix(18)) } == ["req-existing-tests"])

    let tagged = try SendMoneyPlan.replacing(
      SendMoneyPlan.untagged,
      with: "| req-existing-tests | | | | | gate: the final gate runs every area's whole suite, "
        + "APIClient and LogClient included |",
      in: refused)
    #expect(try SendMoneyPlan.screenFindings(tagged).isEmpty)
  }

  @Test(
    "a gate: reason on a screen requirement, and a gate: reason naming no merge or final tier, still fail screen-without-flow, each saying what gate: takes — catches gate: becoming a tag that excuses any journey from its flow"
  )
  func gateReasonExcusesNothingElse() throws {
    let refused = try SendMoneyPlan.refused
    let screen = try #require(
      refused.split(separator: "\n").first { $0.hasPrefix("| req-confirm-screen |") })
    let onScreen = try SendMoneyPlan.replacing(
      String(screen),
      with: "| req-confirm-screen | | | | | gate: final runs every area's whole suite |",
      in: try SendMoneyPlan.replacing(
        SendMoneyPlan.untagged,
        with: "| req-existing-tests | | | | | gate: final runs every area's whole suite |",
        in: refused))
    let screenFindings = try SendMoneyPlan.screenFindings(onScreen)
    #expect(screenFindings.count == 1, "\(screenFindings.map(\.message))")
    let excused = try #require(screenFindings.first)
    #expect(excused.message.hasPrefix("req-confirm-screen"), "\(excused.message)")
    #expect(excused.message.contains("`gate:`"), "\(excused.message)")

    let tierless = try SendMoneyPlan.replacing(
      SendMoneyPlan.untagged,
      with: "| req-existing-tests | | | | | gate: the suites cover it |", in: refused)
    let named = try SendMoneyPlan.screenFindings(tierless)
    #expect(named.count == 1, "\(named.map(\.message))")
    let finding = try #require(named.first)
    #expect(finding.message.hasPrefix("req-existing-tests"), "\(finding.message)")
    #expect(finding.message.contains("`final`"), "\(finding.message)")
  }

  @Test(
    "isGateReason takes gate: followed by text naming merge or final as a word, and nothing else; namesTests takes a title naming tests — catches a tag read from any prefix or tier text"
  )
  func gateReasonShape() {
    #expect(PlanLintValidation.isGateReason("gate: the final gate runs every suite"))
    #expect(PlanLintValidation.isGateReason("  gate:merge runs the whole suite"))
    #expect(!PlanLintValidation.isGateReason("gate: the suites cover it"))
    #expect(!PlanLintValidation.isGateReason("gate: finally covered"))
    #expect(!PlanLintValidation.isGateReason("gate:"))
    #expect(!PlanLintValidation.isGateReason("Gate: final runs it"))
    #expect(!PlanLintValidation.isGateReason("the final gate runs every suite"))
    #expect(PlanLintValidation.namesTests("The existing APIClient and LogClient tests keep passing"))
    #expect(PlanLintValidation.namesTests("Existing test suites stay green"))
    #expect(!PlanLintValidation.namesTests("The confirmation screen shows the contact"))
    #expect(!PlanLintValidation.namesTests("A contest entry form"))
  }
}

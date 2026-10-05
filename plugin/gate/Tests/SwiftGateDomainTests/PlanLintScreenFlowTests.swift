import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// Live plans captured from brownfield trials, linted as `plan import` lints them.
private enum TrialPlan {
  static let directory = Fixture.directory.appending(path: "BrownfieldTrial")

  static func text(_ name: String) throws -> String {
    try String(contentsOf: directory.appending(path: name), encoding: .utf8)
  }

  /// The screen-without-flow findings of `text` with `appAreas` as its `xcode` areas.
  static func screenFindings(
    _ text: String, appAreas: [PlanLintValidation.AppArea]
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
      appAreas: appAreas
    ).filter { $0.ruleID == PlanLintValidation.screenWithoutFlowRuleID }
  }

  static let starter = [PlanLintValidation.AppArea(name: "InterviewStarter", root: ".")]
}

@Suite("plan-lint validation: a screen needs a flow row")
struct PlanLintScreenFlowTests {
  @Test(
    "the tic-tac-toe trial's plan, whose screen task covers 3 requirements checked only by 1 XCUITest class, gets 1 major screen-without-flow per requirement, each naming the requirement, the task and a screen path, at the requirement's first row, and none with no xcode area or 1 rooted where no task writes — catches a UI plan that runs no flow, records no video and proves nothing red first"
  )
  func ticTacToeScreenRequirementsNeedFlows() throws {
    let text = try TrialPlan.text("tic-tac-toe-1-PLAN.md")

    let findings = try TrialPlan.screenFindings(text, appAreas: TrialPlan.starter)

    #expect(findings.count == 3, "\(findings.map(\.message))")
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    for (finding, requirement) in zip(
      findings, ["req-board-screen", "req-status-text", "req-new-game"])
    {
      #expect(finding.severity == .major)
      #expect(finding.message.hasPrefix(requirement), "\(finding.message)")
      #expect(finding.message.contains("`ttt-screen`"), "\(finding.message)")
      #expect(
        finding.message.contains("`Packages/AppFeature/Sources/AppUI/`"), "\(finding.message)")
      let line = try #require(finding.line)
      #expect(lines[line - 1].hasPrefix("| \(requirement) | acceptance |"), "\(lines[line - 1])")
    }

    #expect(try TrialPlan.screenFindings(text, appAreas: []).isEmpty)
    #expect(
      try TrialPlan.screenFindings(
        text, appAreas: [PlanLintValidation.AppArea(name: "ios", root: "ios")]
      ).isEmpty)
  }

  @Test(
    "a Reason on the requirement's row opened with an obstacle kind, or a flow row, clears its finding and leaves the others, and the same Reason without the kind clears nothing — catches a rule that ignores the same-row reason or the flow it asks for, or takes any text as an excuse"
  )
  func reasonOrFlowClearsTheRequirement() throws {
    let text = try TrialPlan.text("tic-tac-toe-1-PLAN.md")
    let old =
      "| req-new-game | acceptance | `test: InterviewStarterUITests/GameFlowUITests` "
      + "| ttt-screen | ttt-screen | |"
    #expect(text.contains(old))
    let reasoned = text.replacingOccurrences(
      of: old,
      with: String(old.dropLast(2)) + " data: needs a 2-player game no flow can set up |")
    let untagged = text.replacingOccurrences(
      of: old, with: String(old.dropLast(2)) + " needs a 2-player game no flow can set up |")
    let flowed = text.replacingOccurrences(
      of: "| req-status-text | acceptance |", with: "| req-status-text | flow |")

    #expect(
      try TrialPlan.screenFindings(reasoned, appAreas: TrialPlan.starter).map {
        String($0.message.prefix { $0 != " " })
      } == ["req-board-screen", "req-status-text"])
    #expect(
      try TrialPlan.screenFindings(untagged, appAreas: TrialPlan.starter).map {
        String($0.message.prefix { $0 != " " })
      } == ["req-board-screen", "req-status-text", "req-new-game"])
    #expect(
      try TrialPlan.screenFindings(flowed, appAreas: TrialPlan.starter).map {
        String($0.message.prefix { $0 != " " })
      } == ["req-board-screen", "req-new-game"])
  }

  @Test(
    "the Aidoku trial's plan, whose setting task writes SettingView with flow rows and whose prompt task writes MangaView with a reason-only row, gets 1 finding naming req-prompt, whose reason names no obstacle kind, none once it opens with `data:`, and 1 again with the row gone — catches a rule that rejects a plan whose screen reason names an obstacle, or misses a bare one"
  )
  func aidokuPlanObstacleClearsPrompt() throws {
    let text = try TrialPlan.text("aidoku-validation-2-PLAN.md")
    let aidoku = [PlanLintValidation.AppArea(name: "Aidoku", root: ".")]
    let reasonRow = try #require(
      text.split(separator: "\n").first { $0.hasPrefix("| req-prompt | | | | |") })

    let findings = try TrialPlan.screenFindings(text, appAreas: aidoku)
    let tagged = try TrialPlan.screenFindings(
      text.replacingOccurrences(
        of: "| req-prompt | | | | | needs", with: "| req-prompt | | | | | data: needs"),
      appAreas: aidoku)
    let bare = try TrialPlan.screenFindings(
      text.replacingOccurrences(of: reasonRow + "\n", with: ""), appAreas: aidoku)

    #expect(findings.count == 1, "\(findings.map(\.message))")
    #expect(findings.first?.message.hasPrefix("req-prompt") == true)
    #expect(tagged.isEmpty, "\(tagged.map(\.message))")
    #expect(bare.count == 1, "\(bare.map(\.message))")
    #expect(bare.first?.message.hasPrefix("req-prompt") == true, "\(bare.map(\.message))")
    #expect(bare.first?.message.contains("`Aidoku/Features/Manga/MangaView.swift`") == true)
  }
}

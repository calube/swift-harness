import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// A trial's plan whose contract holds the clock at launch, while 1 flow row's requirement presses
/// a button that starts the clock-driven state over (`BrownfieldTrial/clock-restart-1-PLAN.md`).
private enum ClockRestartPlan {
  static let contract = "spec-contract"
  static let starter = [PlanLintValidation.AppArea(name: "TimedBuildStarter", root: ".")]

  static var captured: String {
    get throws {
      try String(
        contentsOf: Fixture.directory.appending(
          path: "BrownfieldTrial/clock-restart-1-PLAN.md"), encoding: .utf8)
    }
  }

  static func findings(_ text: String) throws -> [Finding] {
    let plan = try LivePlanParser.parse(text)
    let validation = try #require(plan.validation)
    return try PlanLintValidation.findings(
      table: validation.table, requirements: plan.requirements.map(\.id),
      taskIDs: Set(plan.tasks.map(\.id)), hasIOSArea: true, file: "PLAN.md",
      rowLines: validation.rowLines, sectionLine: validation.headingLine,
      tasks: plan.tasks.map {
        PlanLintValidation.TaskWrites(
          id: $0.id, covers: $0.covers, writes: $0.writes,
          text: PlanLintValidation.briefText($0.brief))
      },
      appAreas: starter, contractTask: contract,
      requirementTitles: Dictionary(
        plan.requirements.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first }))
  }

  /// The 1-based line of the first line of `text` that contains `needle`.
  static func line(of needle: String, in text: String) -> Int? {
    text.split(separator: "\n", omittingEmptySubsequences: false).firstIndex {
      $0.contains(needle)
    }.map { $0 + 1 }
  }
}

@Suite("plan-lint validation: a check after an action that starts the clock over needs it held too")
struct PlanLintClockRestartTests {
  @Test(
    "the captured plan: its contract holds the clock only at launch, and req-ended's flow row checks the screen after `Start again` starts a new session, so clock-unheld fires once at that row's line, naming the contract section and a Scope line that holds the clock after a restart; the launch and the other rows stay clear — catches the plan whose check after the restart raced a live clock and merged unverified"
  )
  func capturedPlanNeedsTheClockHeldAfterRestart() throws {
    let text = try ClockRestartPlan.captured

    let findings = try ClockRestartPlan.findings(text)

    let unheld = findings.filter { $0.ruleID == PlanLintValidation.clockUnheldRuleID }
    #expect(unheld.count == 1, "\(findings.map(\.message))")
    #expect(unheld.first?.line == ClockRestartPlan.line(of: "| req-ended | flow |", in: text))
    let message = try #require(unheld.first?.message)
    #expect(message.contains("`screen-ui`"), "\(message)")
    #expect(message.contains("req-ended's flow row"), "\(message)")
    #expect(message.contains("starts that clock over"), "\(message)")
    #expect(message.contains("PLAN.md's `### spec-contract` section"), "\(message)")
    #expect(message.contains("after a restart"), "\(message)")
    #expect(findings.count == 1, "\(findings.map(\.message))")
  }

  @Test(
    "a contract Scope line that holds the clock after a restart clears the finding — catches a rule no plan can satisfy"
  )
  func heldAfterRestartClears() throws {
    let text = try ClockRestartPlan.captured
    let stub = "  - `TargetFeature` reducer stub in AppCore"
    let stubLine = try #require(
      text.split(separator: "\n").first { $0.hasPrefix(stub) }.map(String.init))
    let held = text.replacingOccurrences(
      of: stubLine,
      with: stubLine
        + "\n  - `launch-held` also holds the clock after Start again, until the next input")

    #expect(try ClockRestartPlan.findings(held).isEmpty)
  }

  @Test(
    "the restart readers: a restart, a reset, a replay, `Start again` or starting a new session restarts the clock, and launching, ending or a held start doesn't; a line holds it after a restart only when it names both — catches a launch read as a restart, or a held launch read as a held restart"
  )
  func readers() {
    for text in [
      "a \"Start again\" button that starts a new session", "the timer restarts", "Reset clears it",
      "replays the sequence", "try again", "begins a new attempt",
    ] {
      #expect(PlanLintValidation.restartsClock(text), "\(text)")
    }
    for text in [
      "Launching the app starts a session with a count of 0", "the session ends at 0 chances",
      "ended clears the trail and starts a held clock", "shows the list again",
    ] {
      #expect(!PlanLintValidation.restartsClock(text), "\(text)")
    }
    #expect(
      PlanLintValidation.holdsClockAfterRestart(
        "`launch-held` also holds the clock after a restart"))
    #expect(
      PlanLintValidation.holdsClockAfterRestart("Start again keeps the clock held until input"))
    #expect(
      !PlanLintValidation.holdsClockAfterRestart(
        "the `launch-held` scenario starts the clock only at the end of the first swipe"))
    #expect(!PlanLintValidation.holdsClockAfterRestart("Start again starts a live session"))
  }
}

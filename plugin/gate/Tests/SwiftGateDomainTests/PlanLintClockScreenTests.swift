import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// A trial's plan for a screen whose state advances on a clock, as `plan import` read it: its
/// screen task's reducer runs a repeating timer from the moment the view appears, its engine takes
/// a seed, and its reason-only rows excuse interactions with moving entities.
private enum ClockScreenPlan {
  static let contract = "spec-contract"
  static let starter = [PlanLintValidation.AppArea(name: "InterviewStarter", root: ".")]

  static var captured: String {
    get throws {
      try String(
        contentsOf: Fixture.directory.appending(
          path: "BrownfieldTrial/clock-screen-1-PLAN.md"), encoding: .utf8)
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

  static func requirements(_ findings: [Finding], _ ruleID: String) -> [String] {
    findings.filter { $0.ruleID == ruleID }.map { String($0.message.prefix { $0 != " " }) }
  }

  /// The 1-based line of the first line of `text` that contains `needle`.
  static func line(of needle: String, in text: String) -> Int? {
    text.split(separator: "\n", omittingEmptySubsequences: false).firstIndex {
      $0.contains(needle)
    }.map { $0 + 1 }
  }

  /// `text` with `old` replaced once.
  static func replacing(_ old: String, with new: String, in text: String) throws -> String {
    let range = try #require(text.range(of: old), "`\(old)` not in the plan")
    return text.replacingCharacters(in: range, with: new)
  }

  /// The contract's scope line that adds the seam, placed after its stub line.
  static let seamLine =
    "  - the composition root reads `-harness-scenario`: `launch-held` holds the clock until the "
    + "first input, and `entity-center` seeds 1 entity at the screen's centre, held"
}

@Suite("plan-lint validation: a screen whose state advances on a clock needs a held scenario, and a seed makes a moving target placeable")
struct PlanLintClockScreenTests {
  @Test(
    "the captured plan: spec-screen's timer drives the screen its req-launch flow row checks while the contract names no `-harness-scenario` seam, so clock-unheld fires once at that row's line; req-motion, req-cut-target and req-hazard, excused as random or moving while the engine takes a seed, are obstacle-seedable; req-seed, req-cut-test and req-miss stay clear — catches the plan whose launch check raced the clock and whose gesture requirements never got a flow"
  )
  func capturedPlanNeedsHeldAndSeededScenarios() throws {
    let text = try ClockScreenPlan.captured

    let findings = try ClockScreenPlan.findings(text)

    let unheld = findings.filter { $0.ruleID == PlanLintValidation.clockUnheldRuleID }
    #expect(unheld.count == 1, "\(findings.map(\.message))")
    #expect(unheld.first?.line == ClockScreenPlan.line(of: "| req-launch | flow |", in: text))
    #expect(unheld.first?.message.contains("`spec-screen`") == true)
    #expect(unheld.first?.message.contains("`spec-contract`") == true)
    #expect(unheld.first?.message.contains("`-harness-scenario`") == true)
    #expect(unheld.first?.message.contains("`held`") == true)
    #expect(
      ClockScreenPlan.requirements(findings, PlanLintValidation.obstacleSeedableRuleID)
        == ["req-motion", "req-cut-target", "req-hazard"], "\(findings.map(\.message))")
    #expect(findings.count == 4, "\(findings.map(\.message))")
    #expect(findings.allSatisfy { $0.severity == .major })
  }

  @Test(
    "a contract scope line that reads `-harness-scenario` and names a held scenario clears clock-unheld, and the seedable reasons still fail until their requirements are flow rows — catches a seam check that a seed alone satisfies, or a held scenario that excuses a gesture"
  )
  func seamClearsUnheldOnly() throws {
    let text = try ClockScreenPlan.captured
    let stub = "  - `TargetFeature` reducer stub in AppCore"
    let stubLine = try #require(
      text.split(separator: "\n").first { $0.hasPrefix(stub) }.map(String.init))
    let seamed = try ClockScreenPlan.replacing(
      stubLine, with: stubLine + "\n" + ClockScreenPlan.seamLine, in: text)

    let held = try ClockScreenPlan.findings(seamed)

    #expect(held.map(\.ruleID).allSatisfy { $0 == PlanLintValidation.obstacleSeedableRuleID })
    #expect(held.count == 3, "\(held.map(\.message))")

    var flowed = seamed
    for requirement in ["req-motion", "req-cut-target", "req-hazard"] {
      let old = try #require(
        seamed.split(separator: "\n").first { $0.hasPrefix("| \(requirement) |") })
      flowed = try ClockScreenPlan.replacing(
        String(old),
        with: "| \(requirement) | flow | `qa/\(requirement).flow.json` | spec-screen | "
          + "spec-validation | |",
        in: flowed)
    }
    #expect(try ClockScreenPlan.findings(flowed).isEmpty)
  }

  @Test(
    "a scenario seam with no held scenario still leaves clock-unheld, and it makes a random-position reason seedable; with no seed and no scenario in any brief, that reason excuses its requirement — catches a seam that can't hold the clock, and a gesture demanded of an engine nothing can place"
  )
  func seamNeedsHeldAndSeedlessReasonsExcuse() throws {
    func findings(contract: String) throws -> [Finding] {
      let tasks = [
        PlanLintValidation.TaskWrites(
          id: "contract", covers: [], writes: ["App/Root.swift"], text: contract),
        PlanLintValidation.TaskWrites(
          id: "screen", covers: ["req-start", "req-hit"],
          writes: ["App/BoardView.swift", "App/BoardFeature.swift"],
          text: "Build the board\n`.task` starts a repeating timer that sends `.tick`"),
      ]
      let table = ValidationTable(
        rows: [
          .init(
            requirement: "req-start", layer: .flow, check: "qa/start.flow.json",
            runsAfter: ["screen"], writer: "screen", reason: nil)
        ],
        unitOnly: [
          .init(requirement: "req-hit", reason: "data: each cell's position is random on screen")
        ])
      return try PlanLintValidation.findings(
        table: table, requirements: ["req-start", "req-hit"], taskIDs: ["contract", "screen"],
        hasIOSArea: true, file: "PLAN.md", tasks: tasks,
        appAreas: [.init(name: "app", root: "App")], contractTask: "contract")
    }

    let seamed = try findings(
      contract: "Declare the stubs\nthe composition root reads `-harness-scenario`: `success`")
    let seedless = try findings(contract: "Declare the stubs")

    #expect(
      seamed.map(\.ruleID)
        == [PlanLintValidation.clockUnheldRuleID, PlanLintValidation.obstacleSeedableRuleID],
      "\(seamed.map(\.message))")
    #expect(seedless.map(\.ruleID) == [PlanLintValidation.clockUnheldRuleID])
  }

  @Test(
    "the brief and reason readers: a timer, clock, tick, TimelineView or display link drives a clock and a clockwise layout doesn't; a held seam needs both `-harness-scenario` and the word held; a seed or a scenario makes an engine placeable; random, moving or moves in a reason's detail names a moving target, and a reason with no obstacle kind doesn't — catches a word match on substrings or on the wrong half of a reason"
  )
  func readers() {
    for text in [
      "runs a repeating timer", "the clock steps", "sends `.tick(seconds:)`", "a `TimelineView`",
      "a CADisplayLink drives it",
    ] {
      #expect(PlanLintValidation.drivesClock(text), "\(text)")
    }
    #expect(!PlanLintValidation.drivesClock("a clockwise layout with a ticket list"))
    #expect(
      PlanLintValidation.holdsClock("reads `-harness-scenario`; `launch-held` holds the clock"))
    #expect(!PlanLintValidation.holdsClock("reads `-harness-scenario`: `success`"))
    #expect(!PlanLintValidation.holdsClock("a held state with no seam"))
    #expect(PlanLintValidation.takesSeedOrScenario("`SeededGenerator` as SplitMix64"))
    #expect(PlanLintValidation.takesSeedOrScenario("reads `-harness-scenario`"))
    #expect(!PlanLintValidation.takesSeedOrScenario("a list of posts"))
    #expect(PlanLintValidation.namesMovingTarget("data: launches are random in the running app"))
    #expect(PlanLintValidation.namesMovingTarget("data: a swipe through a moving entity"))
    #expect(PlanLintValidation.namesMovingTarget("hardware: the target moves too fast"))
    #expect(!PlanLintValidation.namesMovingTarget("data: the seed is internal"))
    #expect(!PlanLintValidation.namesMovingTarget("random: launches"))
    #expect(!PlanLintValidation.namesMovingTarget("launches are random in the running app"))
  }
}

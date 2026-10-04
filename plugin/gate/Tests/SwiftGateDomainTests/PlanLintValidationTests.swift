import SwiftGateDomain
import Testing

private let requirements = ["req-draft-list", "req-offline-save", "req-draft-sync"]
private let tasks: Set<String> = ["draft-list", "save-queue"]

private let flow = ValidationRow(
  requirement: "req-offline-save", layer: .flow, check: "qa/offline-save.flow.json",
  runsAfter: ["save-queue", "draft-list"], writer: "save-queue")
private let state = ValidationRow(
  requirement: "req-offline-save", layer: .state, check: "qa/offline-save.state.sh",
  runsAfter: ["draft-list", "save-queue"], writer: "save-queue")
private let acceptance = ValidationRow(
  requirement: "req-draft-list", layer: .acceptance, check: "DraftListTests",
  runsAfter: ["draft-list"], writer: "draft-list")
private let syncUnitOnly = ValidationUnitOnly(
  requirement: "req-draft-sync", reason: "the sync test in draft-list covers it")

private func lint(
  _ rows: [ValidationRow], unitOnly: [ValidationUnitOnly] = [syncUnitOnly],
  hasIOSArea: Bool = true, rowLines: [Int] = [], sectionLine: Int? = nil
) throws -> [Finding] {
  try PlanLintValidation.findings(
    table: ValidationTable(rows: rows, unitOnly: unitOnly), requirements: requirements,
    taskIDs: tasks, hasIOSArea: hasIOSArea, file: "PLAN.md", rowLines: rowLines,
    sectionLine: sectionLine)
}

@Suite("plan-lint validation table")
struct PlanLintValidationTests {
  @Test(
    "a table with an acceptance row, a flow and its state row, and a unit-only reason lints clean — catches a rule firing on a sound plan"
  )
  func cleanTablePasses() throws {
    #expect(try lint([acceptance, flow, state]).isEmpty)
  }

  @Test(
    "a requirement with no row and no unit-only reason is 1 major validation-uncovered naming it at the section line — catches a requirement no check proves"
  )
  func uncoveredRequirement() throws {
    let findings = try lint([acceptance, flow, state], unitOnly: [], sectionLine: 12)
    #expect(findings.map(\.ruleID) == [PlanLintValidation.uncoveredRuleID])
    #expect(findings.first?.severity == .major)
    #expect(findings.first?.message.contains("req-draft-sync") == true)
    #expect(findings.first?.line == 12)
    #expect(findings.first?.file == "PLAN.md")
  }

  @Test(
    "a Runs after or Writer id with no task is validation-unknown-task naming the id and the row's line — catches a row that waits on a task that never merges"
  )
  func unknownTask() throws {
    let waits = ValidationRow(
      requirement: "req-draft-list", layer: .acceptance, check: "DraftListTests",
      runsAfter: ["draft-list", "draft-lsit"], writer: "draft-list")
    let written = ValidationRow(
      requirement: "req-draft-list", layer: .acceptance, check: "DraftListTests",
      runsAfter: ["draft-list"], writer: "draft-checks")
    let findings = try lint([waits, written, flow, state], rowLines: [20, 21, 22, 23])
    #expect(findings.map(\.ruleID) == Array(repeating: PlanLintValidation.unknownTaskRuleID, count: 2))
    #expect(findings.map(\.line) == [20, 21])
    #expect(findings.first?.message.contains("`draft-lsit`") == true)
    #expect(findings.last?.message.contains("`draft-checks`") == true)
  }

  @Test(
    "a state row with no flow row for its requirement and Runs after is validation-state-without-flow, and an acceptance row stands in only where no iOS area exists — catches a state check with nothing to read"
  )
  func stateWithoutFlow() throws {
    let otherFlow = ValidationRow(
      requirement: "req-offline-save", layer: .flow, check: "qa/offline-save.flow.json",
      runsAfter: ["draft-list"], writer: "save-queue")
    let missing = try lint([acceptance, otherFlow, state], rowLines: [20, 21, 22])
    #expect(missing.map(\.ruleID) == [PlanLintValidation.stateWithoutFlowRuleID])
    #expect(missing.first?.line == 22)

    let boundary = ValidationRow(
      requirement: "req-offline-save", layer: .acceptance, check: "SaveQueueTests",
      runsAfter: ["save-queue", "draft-list"], writer: "save-queue")
    #expect(
      try lint([acceptance, boundary, state]).map(\.ruleID)
        == [PlanLintValidation.stateWithoutFlowRuleID])
    #expect(try lint([acceptance, boundary, state], hasIOSArea: false).isEmpty)
  }

  @Test(
    "a flow row in a repository with no iOS area is validation-flow-without-ios naming its line — catches a flow that has no app to drive"
  )
  func flowWithoutIOS() throws {
    let findings = try lint([acceptance, flow], hasIOSArea: false, rowLines: [20, 21])
    #expect(findings.map(\.ruleID) == [PlanLintValidation.flowWithoutIOSRuleID])
    #expect(findings.first?.line == 21)
    #expect(findings.first?.severity == .major)
    #expect(try lint([acceptance, flow]).isEmpty)
  }
}

import Testing

@testable import SwiftGateDomain

@Suite("PlanLintCoverage.missingModelFindings")
struct PlanLintModelTagTests {

  private static func task(model: TaskModel?) -> LedgerTask {
    LedgerTask(
      id: "some-task", deps: [], writeSet: ["Sources/SomeModule/File.swift"], gate: .fast,
      tests: [], covers: [], estLines: 100, status: .pending,
      worktree: "../swift-harness-some-task", model: model)
  }

  @Test(
    "a task with no model is a major missing-model finding — catches an untagged task reaching build next"
  )
  func untaggedTaskIsMajorFinding() throws {
    let findings = try PlanLintCoverage.missingModelFindings(task: Self.task(model: nil))
    #expect(findings.count == 1)
    #expect(findings[0].ruleID == PlanLintCoverage.missingModelRuleID)
    #expect(findings[0].severity == .major)
    #expect(findings[0].file == "some-task")
    #expect(findings[0].message.contains("some-task"))
  }

  @Test(
    "a task tagged sonnet or opus has no missing-model finding — catches a false positive on a tagged task"
  )
  func taggedTaskHasNoFinding() throws {
    #expect(try PlanLintCoverage.missingModelFindings(task: Self.task(model: .sonnet)).isEmpty)
    #expect(try PlanLintCoverage.missingModelFindings(task: Self.task(model: .opus)).isEmpty)
  }
}

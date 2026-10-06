import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// Captured brownfield plans, run through the check-dependency lint as `plan import` runs it.
private enum CapturedPlan {
  static func text(_ name: String) throws -> String {
    try String(
      contentsOf: Fixture.directory.appending(path: "BrownfieldTrial/\(name)"), encoding: .utf8)
  }

  static func findings(_ text: String) throws -> [Finding] {
    let plan = try LivePlanParser.parse(text)
    return try PlanLintCheckDependencies.findings(
      tasks: plan.tasks.map {
        PlanLintCheckDependencies.Task(
          id: $0.id, deps: $0.deps, writes: $0.writes, acceptance: $0.brief.acceptance)
      },
      table: plan.validation?.table, file: "PLAN.md", rowLines: plan.validation?.rowLines ?? [])
  }

  /// `text` with the line starting `prefix` replaced by `line`; fails the test when none does.
  static func replacingLine(starting prefix: String, with line: String, in text: String) throws
    -> String
  {
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let index = try #require(lines.firstIndex { $0.hasPrefix(prefix) }, "no line `\(prefix)`")
    lines[index] = line
    return lines.joined(separator: "\n")
  }

  static let rootFlowDeps = "- Deps: send-money-contract · Gate: slice · estLines: 300"
}

@Suite("plan-lint: a task whose check exercises another task's work depends on it")
struct PlanLintCheckDependenciesTests {
  @Test(
    "the send-money plan with req-replace-screen as root-flow's launch UI test row running after root-flow and account-fake gets 1 major check-missing-dependency at that row naming both tasks, and none once root-flow depends on account-fake, directly or through another task — catches the trial's root-flow merging a UI test that needs account-fake's fake before account-fake"
  )
  func rowWriterWaitsForEveryRunsAfterTask() throws {
    let row =
      "| req-replace-screen | acceptance | `test: TimedBuildStarterUITests/LaunchFlowUITests` "
      + "| root-flow, account-fake | root-flow | |"
    let text = try CapturedPlan.replacingLine(
      starting: "| req-replace-screen |", with: row,
      in: try CapturedPlan.text("send-money-1-PLAN.md"))

    let findings = try CapturedPlan.findings(text)

    #expect(findings.count == 1, "\(findings.map(\.message))")
    let finding = try #require(findings.first)
    #expect(finding.ruleID == PlanLintCheckDependencies.ruleID)
    #expect(finding.severity == .major)
    #expect(finding.message.contains("`root-flow`"), "\(finding.message)")
    #expect(finding.message.contains("`account-fake`"), "\(finding.message)")
    let rowLine = text.split(separator: "\n", omittingEmptySubsequences: false)
      .firstIndex { $0 == row }.map { $0 + 1 }
    #expect(finding.line == rowLine)

    let direct = text.replacingOccurrences(
      of: CapturedPlan.rootFlowDeps,
      with: "- Deps: send-money-contract, account-fake · Gate: slice · estLines: 300")
    let transitive = direct.replacingOccurrences(
      of: "- Deps: send-money-contract, account-fake · Gate: slice · estLines: 300",
      with: "- Deps: amount-confirm · Gate: slice · estLines: 300"
    ).replacingOccurrences(
      of: "- Deps: send-money-contract · Gate: slice · estLines: 320",
      with: "- Deps: account-fake · Gate: slice · estLines: 320")
    #expect(try CapturedPlan.findings(direct).isEmpty)
    #expect(try CapturedPlan.findings(transitive).isEmpty)
  }

  @Test(
    "an acceptance item of amount-confirm naming AmountInput, which amount-rules writes as AmountInput.swift, gets 1 major finding naming both tasks and the file, and none once amount-confirm depends on amount-rules — catches a task whose own test reaches into a parallel task's file"
  )
  func acceptanceNamingAnotherTasksFile() throws {
    let captured = try CapturedPlan.text("send-money-1-PLAN.md")
    let item = "  - AmountFeatureTests: keys reach the input"
    #expect(captured.contains(item))
    let text = captured.replacingOccurrences(
      of: item, with: "  - AmountFeatureTests: keys reach AmountInput's press rules")

    let findings = try CapturedPlan.findings(text)

    #expect(findings.count == 1, "\(findings.map(\.message))")
    let message = try #require(findings.first?.message)
    #expect(message.contains("`amount-confirm`"), "\(message)")
    #expect(message.contains("`amount-rules`"), "\(message)")
    #expect(message.contains("Packages/AppFeature/Sources/AppCore/AmountInput.swift"), "\(message)")
    let waiting = text.replacingOccurrences(
      of: "- Deps: send-money-contract · Gate: slice · estLines: 320",
      with: "- Deps: send-money-contract, amount-rules · Gate: slice · estLines: 320")
    #expect(try CapturedPlan.findings(waiting).isEmpty)
  }

  @Test(
    "an acceptance item naming a path under a prefix another task writes is a finding, and a stem the task writes itself, or a word that only contains another task's stem, is not — catches a match on substrings or on files the task shares"
  )
  func acceptanceMatchesPathsAndWholeNames() throws {
    let captured = try CapturedPlan.text("send-money-1-PLAN.md")
    let item = "  - AmountFeatureTests: keys reach the input"
    let byPath = captured.replacingOccurrences(
      of: item,
      with: item + " through Packages/AccountClient/Sources/AccountClient/InMemory.swift")
    let ownAndSubstring = captured.replacingOccurrences(
      of: item, with: item + " as AmountView shows, with AmountInputs unknown")

    let pathFindings = try CapturedPlan.findings(byPath)

    #expect(pathFindings.count == 1, "\(pathFindings.map(\.message))")
    #expect(pathFindings.first?.message.contains("`account-fake`") == true)
    #expect(try CapturedPlan.findings(ownAndSubstring).isEmpty)
  }

  @Test(
    "the captured send-money, tic-tac-toe, Aidoku and memos plans as written get no finding — catches a rule that flags a validation task's rows, a writer alone in its Runs after, or a plan's own shared names"
  )
  func capturedPlansPass() throws {
    for name in [
      "send-money-1-PLAN.md", "tic-tac-toe-1-PLAN.md", "aidoku-validation-2-PLAN.md",
      "memos-4-validation-PLAN.md", "memos-4-PLAN.md",
    ] {
      let findings = try CapturedPlan.findings(try CapturedPlan.text(name))
      #expect(findings.isEmpty, "\(name): \(findings.map(\.message))")
    }
  }
}

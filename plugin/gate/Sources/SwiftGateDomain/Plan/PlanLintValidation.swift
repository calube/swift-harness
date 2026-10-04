/// `plan-lint`'s checks of a plan's validation table (simulator QA amendment §4.3). Pure: the
/// table, the requirement ids and the task ids arrive already read.
public enum PlanLintValidation {
  public static let uncoveredRuleID = "plan-lint.validation-uncovered"
  public static let unknownTaskRuleID = "plan-lint.validation-unknown-task"
  public static let stateWithoutFlowRuleID = "plan-lint.validation-state-without-flow"
  public static let flowWithoutIOSRuleID = "plan-lint.validation-flow-without-ios"

  /// Every finding, each `major`: uncovered requirements in plan order, then each row's findings
  /// in table order.
  ///
  /// - Parameters:
  ///   - requirements: the plan's requirement ids, in plan order.
  ///   - taskIDs: every ledger task id.
  ///   - hasIOSArea: whether the repository has an app a flow can drive.
  ///   - file: the file findings name: `PLAN.md` or `validation.json`.
  ///   - rowLines: the line of each of `table.rows`, when the table came from markdown.
  ///   - sectionLine: the line the table starts on, when it came from markdown.
  public static func findings(
    table: ValidationTable, requirements: [String], taskIDs: Set<String>, hasIOSArea: Bool,
    file: String, rowLines: [Int] = [], sectionLine: Int? = nil
  ) throws(ReportContractViolation) -> [Finding] {
    var findings: [Finding] = []
    let checked = Set(table.rows.map(\.requirement) + table.unitOnly.map(\.requirement))
    for requirement in requirements where !checked.contains(requirement) {
      findings.append(
        try Finding(
          ruleID: uncoveredRuleID, severity: .major, file: file, line: sectionLine,
          message:
            "\(requirement) has no validation row and no unit-only reason: give it an "
            + "acceptance, flow or state check, or a row whose Reason says its unit tests suffice",
          failureScenario:
            "every task covering \(requirement) merges green, and nothing checks it end to end"))
    }

    for (index, row) in table.rows.enumerated() {
      let line = index < rowLines.count ? rowLines[index] : nil
      let place = "\(row.requirement)'s \(row.layer.rawValue) row"
      for id in row.runsAfter where !taskIDs.contains(id) {
        findings.append(
          try Finding(
            ruleID: unknownTaskRuleID, severity: .major, file: file, line: line,
            message: "\(place) runs after `\(id)`, which is no task in the plan",
            failureScenario: "`\(id)` never merges, so the row waits for ever and never runs"))
      }
      if !taskIDs.contains(row.writer) {
        findings.append(
          try Finding(
            ruleID: unknownTaskRuleID, severity: .major, file: file, line: line,
            message: "\(place) is written by `\(row.writer)`, which is no task in the plan",
            failureScenario: "no worker is told to write `\(row.check)`, so the row has no check"))
      }
      if row.layer == .flow, !hasIOSArea {
        findings.append(
          try Finding(
            ruleID: flowWithoutIOSRuleID, severity: .major, file: file, line: line,
            message:
              "\(place) drives an app, but the repository has no Xcode area; check the "
              + "boundary with an acceptance row instead",
            failureScenario: "the flow has no app to launch, so the row can never pass"))
      }
      if row.layer == .state, !hasPrecedingRow(row, in: table.rows, hasIOSArea: hasIOSArea) {
        let expected = hasIOSArea ? "a flow row" : "a flow or acceptance row"
        findings.append(
          try Finding(
            ruleID: stateWithoutFlowRuleID, severity: .major, file: file, line: line,
            message:
              "\(place) has no \(expected) for the same requirement that runs after the same "
              + "tasks (\(row.runsAfter.joined(separator: ", ")))",
            failureScenario:
              "the state script reads a result nothing in the run produced, so it passes or "
              + "fails on leftovers"))
      }
    }
    return findings
  }

  /// Whether a flow row, or where no app exists an acceptance row, produces what `state` reads:
  /// the same requirement, after the same tasks.
  private static func hasPrecedingRow(
    _ state: ValidationRow, in rows: [ValidationRow], hasIOSArea: Bool
  ) -> Bool {
    let tasks = Set(state.runsAfter)
    return rows.contains { row in
      let producer = row.layer == .flow || (!hasIOSArea && row.layer == .acceptance)
      return producer && row.requirement == state.requirement && Set(row.runsAfter) == tasks
    }
  }
}

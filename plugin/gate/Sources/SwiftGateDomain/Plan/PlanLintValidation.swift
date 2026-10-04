/// `plan-lint`'s checks of a plan's validation table (simulator QA amendment §4.3). Pure: the
/// table, the requirement ids and the task ids arrive already read.
public enum PlanLintValidation {
  public static let uncoveredRuleID = "plan-lint.validation-uncovered"
  public static let unknownTaskRuleID = "plan-lint.validation-unknown-task"
  public static let stateWithoutFlowRuleID = "plan-lint.validation-state-without-flow"
  public static let flowWithoutIOSRuleID = "plan-lint.validation-flow-without-ios"

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
    []
  }
}

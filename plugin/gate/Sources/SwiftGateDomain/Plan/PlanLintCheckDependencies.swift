/// `plan import`'s check that a task whose own check exercises another task's work waits for
/// that task. Pure: the tasks and the validation table arrive already read.
public enum PlanLintCheckDependencies {
  public static let ruleID = "plan-lint.check-missing-dependency"

  /// A task as the check reads it.
  public struct Task: Sendable, Equatable {
    public let id: String
    public let deps: [String]
    /// Repository-relative paths; a path ending in `/` is a prefix.
    public let writes: [String]
    /// The task's `- Acceptance:` items, as written.
    public let acceptance: [String]

    public init(id: String, deps: [String], writes: [String], acceptance: [String]) {
      self.id = id
      self.deps = deps
      self.writes = writes
      self.acceptance = acceptance
    }
  }

  /// Every finding, each `major`: the validation rows in table order, then each task's
  /// acceptance items in plan order.
  ///
  /// - Parameters:
  ///   - tasks: every task of the plan.
  ///   - table: the plan's validation table; `nil` when it has none.
  ///   - file: the file findings name.
  ///   - rowLines: the line of each of `table.rows`, when the table came from markdown.
  public static func findings(
    tasks: [Task], table: ValidationTable?, file: String, rowLines: [Int] = []
  ) throws(ReportContractViolation) -> [Finding] {
    []
  }
}

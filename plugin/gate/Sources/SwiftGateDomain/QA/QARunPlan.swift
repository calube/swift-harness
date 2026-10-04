import Foundation

/// Which validation rows 1 `qa run` takes, in the order it runs them: acceptance, then flow, then
/// state, each layer in table order.
public struct QARunPlan: Sendable, Equatable {
  public struct Entry: Sendable, Equatable {
    /// 1-based position in the table's `rows`.
    public let row: Int
    public let validation: ValidationRow
    /// The row's unmerged `runsAfter` tasks, in its order; empty when the row runs.
    public let waitingOn: [String]

    public init(row: Int, validation: ValidationRow, waitingOn: [String] = []) {
      self.row = row
      self.validation = validation
      self.waitingOn = waitingOn
    }
  }

  public static let flowRunnerMissing = "flow runner not built"

  public let entries: [Entry]

  public init(entries: [Entry]) {
    self.entries = entries
  }

  /// - Parameters:
  ///   - merged: the tasks merged so far; `nil` takes every row as ready, as a run at the merge
  ///     base does, since there no row's tasks have merged by definition.
  ///   - after: when set, only the rows whose `runsAfter` names this task.
  public static func make(table: ValidationTable, merged: Set<String>?, after: String?)
    -> QARunPlan
  {
    QARunPlan(entries: [])
  }

  /// Runs the ready entries layer by layer through `check` and returns 1 row per entry, in plan
  /// order.
  /// - Parameter atBase: `false` stops at the first layer with a red row, leaving every later
  ///   row `unverified`, and runs a state row only once every flow row for its requirement in
  ///   this plan passed. `true` runs every ready row, since each is expected to fail there.
  public func execute(atBase: Bool, check: (Entry) async -> QACheckOutcome) async -> [QARow] {
    []
  }
}

/// What running 1 row's check showed.
public struct QACheckOutcome: Sendable, Equatable {
  /// `pass`, `red` or `unverified`; a check that ran is never `waiting`.
  public let result: QAResult
  public let message: String
  public let exitStatus: Int?
  public let milliseconds: Int
  public let evidence: [String]

  public init(
    result: QAResult, message: String, exitStatus: Int? = nil, milliseconds: Int = 0,
    evidence: [String] = []
  ) {
    self.result = result
    self.message = message
    self.exitStatus = exitStatus
    self.milliseconds = milliseconds
    self.evidence = evidence
  }
}

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
  /// A slower layer can't pass over a broken boundary, so the layers run cheapest first.
  public static let layerOrder: [ValidationLayer] = [.acceptance, .flow, .state]

  public let entries: [Entry]

  public init(entries: [Entry]) {
    self.entries = entries
  }

  /// - Parameters:
  ///   - merged: the tasks merged so far; `nil` takes every row as ready, as a run at the merge
  ///     base does, since there no row's tasks have merged by definition.
  ///   - after: when set, only the rows whose `runsAfter` names this task, which counts as
  ///     merged: the caller runs this straight after merging it.
  public static func make(table: ValidationTable, merged: Set<String>?, after: String?)
    -> QARunPlan
  {
    let numbered = table.rows.enumerated().map { (row: $0.offset + 1, validation: $0.element) }
    let entries = layerOrder.flatMap { layer in
      numbered
        .filter { $0.validation.layer == layer }
        .filter { candidate in after.map { candidate.validation.runsAfter.contains($0) } ?? true }
        .map { candidate in
          let unmerged =
            merged.map { merged in
              candidate.validation.runsAfter.filter { !merged.contains($0) && $0 != after }
            } ?? []
          return Entry(row: candidate.row, validation: candidate.validation, waitingOn: unmerged)
        }
    }
    return QARunPlan(entries: entries)
  }

  /// Runs the ready entries layer by layer through `check` and returns 1 row per entry, in plan
  /// order.
  /// - Parameter atBase: `false` stops at the first layer with a red row, leaving every later
  ///   row `unverified`, and runs a state row only once every flow row for its requirement in
  ///   this plan passed. `true` runs every ready row, since each is expected to fail there.
  public func execute(atBase: Bool, check: (Entry) async -> QACheckOutcome) async -> [QARow] {
    var rows: [QARow] = []
    var redLayer: ValidationLayer?
    var flows: [String: [QARow]] = [:]
    for entry in entries {
      let validation = entry.validation
      let row: QARow
      if !entry.waitingOn.isEmpty {
        row = Self.row(
          entry, result: .waiting,
          message: "waiting on \(entry.waitingOn.joined(separator: ", "))",
          waitingOn: entry.waitingOn)
      } else if !atBase, let redLayer, redLayer != validation.layer {
        row = Self.row(
          entry, result: .unverified,
          message: "not run: the \(redLayer.rawValue) layer has a red row")
      } else if !atBase, validation.layer == .state,
        let flow = flows[validation.requirement]?.first(where: { $0.result != .pass })
      {
        row = Self.row(
          entry, result: .unverified,
          message:
            "not run: flow row \(flow.row) `\(flow.check)` for \(validation.requirement) is "
            + flow.result.rawValue)
      } else {
        let outcome = await check(entry)
        row = QARow(
          row: entry.row, requirement: validation.requirement, layer: validation.layer,
          check: validation.check, runsAfter: validation.runsAfter, result: outcome.result,
          message: outcome.message, exitStatus: outcome.exitStatus,
          milliseconds: outcome.milliseconds, evidence: outcome.evidence)
        if outcome.result == .red, redLayer == nil { redLayer = validation.layer }
      }
      if validation.layer == .flow { flows[validation.requirement, default: []].append(row) }
      rows.append(row)
    }
    return rows
  }

  private static func row(
    _ entry: Entry, result: QAResult, message: String, waitingOn: [String] = []
  ) -> QARow {
    QARow(
      row: entry.row, requirement: entry.validation.requirement, layer: entry.validation.layer,
      check: entry.validation.check, runsAfter: entry.validation.runsAfter, result: result,
      message: message, waitingOn: waitingOn)
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

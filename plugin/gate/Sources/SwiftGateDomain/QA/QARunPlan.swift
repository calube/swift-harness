import Foundation

/// Which validation rows 1 `qa run` takes, in the order it runs them: acceptance, then flow, then
/// state, each layer in table order, except that a requirement's state rows run straight after its
/// last flow row, on that flow's device.
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
  /// A slower layer can't pass over its requirement's broken boundary, so the layers run cheapest
  /// first.
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
    let layered = layerOrder.flatMap { layer in
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
    return QARunPlan(entries: statesAfterTheirFlows(layered))
  }

  /// Moves each requirement's state rows to just after its last flow row: a state check reads
  /// what the flow left on its device, which goes back before the next flow starts. A state row
  /// whose requirement has no flow row stays at the end.
  private static func statesAfterTheirFlows(_ entries: [Entry]) -> [Entry] {
    let flowRequirements = Set(
      entries.filter { $0.validation.layer == .flow }.map(\.validation.requirement))
    let attached = entries.filter {
      $0.validation.layer == .state && flowRequirements.contains($0.validation.requirement)
    }
    var ordered: [Entry] = []
    let flows = entries.filter { $0.validation.layer == .flow }
    for entry in entries where !attached.contains(entry) {
      ordered.append(entry)
      let requirement = entry.validation.requirement
      if entry.validation.layer == .flow,
        flows.last(where: { $0.validation.requirement == requirement }) == entry
      {
        ordered += attached.filter { $0.validation.requirement == requirement }
      }
    }
    return ordered
  }

  /// Runs the ready entries layer by layer through `check` and returns 1 row per entry, in plan
  /// order.
  /// - Parameter atBase: `false` leaves a requirement's later-layer rows `unverified` once 1 of its
  ///   rows reads red, and runs a state row only once every flow row for its requirement in this
  ///   plan passed; another requirement's red row stops nothing, since it crosses another
  ///   boundary. `true` runs every ready row, since each is expected to fail there, except a state
  ///   row whose flow row didn't run: with no device, its red would prove nothing.
  public func execute(atBase: Bool, check: (Entry) async -> QACheckOutcome) async -> [QARow] {
    var rows: [QARow] = []
    var reds: [String: QARow] = [:]
    var flows: [String: [QARow]] = [:]
    for entry in entries {
      let validation = entry.validation
      let row: QARow
      if !entry.waitingOn.isEmpty {
        row = Self.row(
          entry, result: .waiting,
          message: "waiting on \(entry.waitingOn.joined(separator: ", "))",
          waitingOn: entry.waitingOn)
      } else if !atBase, let red = reds[validation.requirement],
        Self.precedes(red.layer, validation.layer)
      {
        row = Self.row(
          entry, result: .unverified,
          message:
            "not run: \(red.layer.rawValue) row \(red.row) `\(red.check)` for "
            + "\(validation.requirement) is red")
      } else if validation.layer == .state,
        let flow = flows[validation.requirement]?.first(where: {
          atBase ? $0.result == .unverified || $0.result == .waiting : $0.result != .pass
        })
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
        if outcome.result == .red, reds[validation.requirement] == nil {
          reds[validation.requirement] = row
        }
      }
      if validation.layer == .flow { flows[validation.requirement, default: []].append(row) }
      rows.append(row)
    }
    return rows
  }

  /// Whether `earlier` runs before `later` in ``layerOrder``.
  private static func precedes(_ earlier: ValidationLayer, _ later: ValidationLayer) -> Bool {
    (layerOrder.firstIndex(of: earlier) ?? 0) < (layerOrder.firstIndex(of: later) ?? 0)
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

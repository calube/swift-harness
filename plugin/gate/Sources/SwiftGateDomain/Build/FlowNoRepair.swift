import Foundation

/// A flow repair worker's `no repair: <requirement>: <why>` return: it could rewrite no flow to
/// make the row pass. Its cause decides what the build does with the row's task.
public struct FlowNoRepair: Sendable, Equatable {
  public enum Cause: Sendable, Equatable {
    /// The row needs a contract name the app doesn't have, such as a scenario that holds a
    /// transient state; `nil` when the line names none.
    case contractGap(name: String?)
    /// The flow drives what the requirement needs and the app doesn't do it.
    case appAtFault
    /// The red run's frames show the app in a state the requirement rules out: `frame` names
    /// where, `nil` when the line names none.
    case appDefect(frame: String?)
  }

  public static let prefix = "no repair:"
  /// What a contract gap's reason starts with:
  /// `no repair: <requirement>: contract gap: <name>: <why>`.
  public static let contractGapMarker = "contract gap:"
  /// What an app defect's reason starts with:
  /// `no repair: <requirement>: app defect: <frame>: <what it shows>`.
  public static let appDefectMarker = "app defect:"

  public let requirement: String
  public let cause: Cause
  public let why: String

  public init(requirement: String, cause: Cause, why: String) {
    self.requirement = requirement
    self.cause = cause
    self.why = why
  }

  /// The first `no repair:` line of a worker's reply; `nil` when it has none or names no
  /// requirement.
  public static func parse(_ reply: String) -> FlowNoRepair? {
    for raw in reply.split(separator: "\n") {
      let line = raw.trimmingCharacters(in: .whitespaces)
      guard line.hasPrefix(prefix) else { continue }
      let rest = line.dropFirst(prefix.count)
      guard let colon = rest.firstIndex(of: ":") else { return nil }
      let requirement = rest[..<colon].trimmingCharacters(in: .whitespaces)
      guard !requirement.isEmpty, !requirement.contains(" ") else { return nil }
      let reason = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      guard reason.lowercased().hasPrefix(contractGapMarker) else {
        // The cause in prose, as the repair-mode reference words it, with no marker.
        let gap = reason.lowercased().contains("contract name")
        return FlowNoRepair(
          requirement: requirement, cause: gap ? .contractGap(name: nil) : .appAtFault,
          why: reason)
      }
      let named = reason.dropFirst(contractGapMarker.count)
      guard let end = named.firstIndex(of: ":") else {
        let only = named.trimmingCharacters(in: .whitespaces)
        let isName = !only.isEmpty && !only.contains(" ")
        return FlowNoRepair(
          requirement: requirement, cause: .contractGap(name: isName ? only : nil),
          why: isName ? "" : only)
      }
      let name = named[..<end].trimmingCharacters(in: .whitespaces)
      return FlowNoRepair(
        requirement: requirement, cause: .contractGap(name: name.isEmpty ? nil : name),
        why: named[named.index(after: end)...].trimmingCharacters(in: .whitespaces))
    }
    return nil
  }
}

/// What the build does with a task whose flow row got a `no repair:` return. Stopping the build
/// is never an answer: the rest of the plan's work doesn't depend on 1 row.
public struct NoRepairDecision: Sendable, Equatable, Encodable {
  public enum Action: String, Sendable, Equatable, Encodable {
    /// The orchestrator adds the missing name to the contract on the plan branch, then sends the
    /// row back to the repair worker and the fixer runs again. No halt.
    case amendContract = "amend-contract"
    /// `build merge --fix` takes the task with ``NoRepairDecision/rows`` left unverified, which
    /// the final `qa run` reports with the reason. Halt, then `build resume --answer merge`.
    case mergeUnverified = "merge-unverified"
    /// The task stays `blocked` and the build goes on without it. Halt, then
    /// `build resume --answer continue`.
    case `continue`
    /// The frames show an app defect: the fixer runs again, its brief quoting the defect, while 1
    /// more fix round fits before the cutoff. Halt, then `build resume --answer retry`.
    case fixAgain = "fix-again"
  }

  public let action: Action
  /// The requirement's rows in the red run that didn't pass, 1-based table positions.
  public let rows: [Int]
  public let why: String

  public init(action: Action, rows: [Int], why: String) {
    self.action = action
    self.rows = rows
    self.why = why
  }

  /// - Parameters:
  ///   - noRepair: the repair worker's return.
  ///   - run: the rows of the before-merge `qa run` the row was red in, at the fixer's tip.
  ///   - runSeconds: how long that run took; an amendment costs the repair worker's at-base proof
  ///     and the fixer's before-merge run, about 2 of it.
  ///   - fixGate: the verdict of the gate the fixer's return cites; `nil` when it cites none.
  ///   - noNewStartsAt: after it no amendment round starts; `nil` for a build with no box.
  ///   - cutoffAt: from then `build cutoff` decides the task; `nil` for a build with no box.
  ///   - fixRound: 1 more fix round of the task as this run measured it; `nil` prices it as
  ///     `runSeconds`.
  public static func decide(
    _ noRepair: FlowNoRepair, run: [QARow], runSeconds: Int, fixGate: Verdict?, now: Date,
    noNewStartsAt: Date?, cutoffAt: Date?, fixRound: TaskHaltAdvice.FixRound? = nil
  ) -> NoRepairDecision {
    let requirement = noRepair.requirement
    let left = run.filter { $0.requirement == requirement && $0.result != .pass }
    let rows = left.map(\.row)
    let named = Self.named(left)
    if let cutoffAt, now >= cutoffAt {
      return NoRepairDecision(
        action: .continue, rows: rows,
        why: "the cutoff passed at \(stamp(cutoffAt)): `build cutoff` decides the task")
    }
    guard !left.isEmpty else {
      return NoRepairDecision(
        action: .continue, rows: [],
        why: "no row of `\(requirement)` failed in this run: decide on the run its row was red in")
    }
    if case .contractGap(let name) = noRepair.cause {
      let round = 2 * max(0, runSeconds)
      let fits = noNewStartsAt.map { now.addingTimeInterval(TimeInterval(round)) <= $0 } ?? true
      if fits {
        return NoRepairDecision(
          action: .amendContract, rows: rows,
          why: "\(named) needs a contract name the app doesn't have"
            + (name.map { " (`\($0)`)" } ?? "")
            + ": add it to the contract on the plan branch, then repair the row again and run "
            + "the fixer; the repair's proof and the fixer's run take about \(round) s"
            + (noNewStartsAt.map {
              ", and \(Int($0.timeIntervalSince(now))) s remain before no new starts"
            } ?? ""))
      }
    }
    guard fixGate == .green else {
      return NoRepairDecision(
        action: .continue, rows: rows,
        why: "the fixer's return cites "
          + (fixGate.map { "a \($0.rawValue) gate" } ?? "no gate")
          + ", so nothing proved its code: the task stays blocked and the build goes on")
    }
    let others = run.filter {
      $0.requirement != requirement && $0.result != .pass && $0.result != .waiting
    }
    guard others.isEmpty else {
      return NoRepairDecision(
        action: .continue, rows: rows,
        why: "\(Self.named(others)) didn't pass either: the task stays blocked and the build "
          + "goes on")
    }
    let cause: String =
      switch noRepair.cause {
      case .contractGap(let name):
        "a contract name the app doesn't have" + (name.map { " (`\($0)`)" } ?? "")
          + ", with too little time to add it before no new starts"
      case .appAtFault, .appDefect: "the app, by the repair worker's reading"
      }
    return NoRepairDecision(
      action: .mergeUnverified, rows: rows,
      why: "the fixer's gate is GREEN and every other row of the run passed: merge the task with "
        + "\(named) left unverified, which the report names; its flow fails on \(cause)")
  }

  /// `row 3 (req-a)`, or `rows 3, 4 (req-a, req-b)`.
  private static func named(_ rows: [QARow]) -> String {
    var requirements: [String] = []
    for row in rows where !requirements.contains(row.requirement) {
      requirements.append(row.requirement)
    }
    return (rows.count == 1 ? "row " : "rows ")
      + rows.map { String($0.row) }.joined(separator: ", ")
      + " (\(requirements.joined(separator: ", ")))"
  }

  private static func stamp(_ date: Date) -> String {
    date.formatted(.iso8601)
  }
}

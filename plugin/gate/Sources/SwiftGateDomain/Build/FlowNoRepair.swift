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
  }

  public static let prefix = "no repair:"
  /// What a contract gap's reason starts with: `no repair: <requirement>: contract gap: <name>: <why>`.
  public static let contractGapMarker = "contract gap:"

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
    nil
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
  public static func decide(
    _ noRepair: FlowNoRepair, run: [QARow], runSeconds: Int, fixGate: Verdict?, now: Date,
    noNewStartsAt: Date?, cutoffAt: Date?
  ) -> NoRepairDecision {
    NoRepairDecision(action: .continue, rows: [], why: "")
  }
}

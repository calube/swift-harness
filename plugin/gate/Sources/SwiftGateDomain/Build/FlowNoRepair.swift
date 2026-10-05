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
      if reason.lowercased().hasPrefix(appDefectMarker) {
        let shown = reason.dropFirst(appDefectMarker.count)
        guard let end = shown.firstIndex(of: ":") else {
          return FlowNoRepair(
            requirement: requirement, cause: .appDefect(frame: nil),
            why: shown.trimmingCharacters(in: .whitespaces))
        }
        let frame = shown[..<end].trimmingCharacters(in: .whitespaces)
        return FlowNoRepair(
          requirement: requirement, cause: .appDefect(frame: frame.isEmpty ? nil : frame),
          why: shown[shown.index(after: end)...].trimmingCharacters(in: .whitespaces))
      }
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
    /// The row goes back to the repair worker, its flow naming the missing name, and the fixer
    /// runs again to add that name to the contract on the fix branch, while the repair's proof
    /// and 1 more fix round end before the cutoff. No halt.
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

  /// How an `amend-contract` amendment lands, the 1 path its advice names: the fixer writes it,
  /// and the orchestrator writes neither the amendment nor the fixer's return.
  public static let amendmentPath =
    "repair the row again, its flow naming the new name, then relaunch the fixer in its fix "
    + "worktree, its brief quoting this line: it adds the name to the contract, commits it on the "
    + "fix branch, names each file that commit changed in its notes, and runs its gate and the "
    + "before-merge `qa run --fix`; never write the amendment or the fixer's return yourself"

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
  ///   - runSeconds: how long that run took; it prices 1 more fix round when `fixRound` is
  ///     `nil`. An amendment costs the repair worker's at-base proof of the red rows, priced as
  ///     those rows took in the run, and 1 more fix round.
  ///   - fixGate: the verdict of the gate the fixer's return cites; `nil` when it cites none.
  ///   - noNewStartsAt: no new starts; a started task's amendment or fix round isn't one.
  ///   - cutoffAt: from then `build cutoff` decides the task, and an amendment or a fix round
  ///     must end before it; `nil` for a build with no box.
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
    if case .appDefect(let frame) = noRepair.cause {
      let shown =
        "\(named) fails on an app defect its frames show"
        + (frame.map { " (\($0))" } ?? "") + (noRepair.why.isEmpty ? "" : ": \(noRepair.why)")
      let round = fixRound?.seconds ?? max(0, runSeconds)
      guard let cutoffAt, now.addingTimeInterval(TimeInterval(round)) > cutoffAt else {
        return NoRepairDecision(
          action: .fixAgain, rows: rows,
          why: "\(shown). Relaunch the fixer, its brief quoting the defect and the red run's "
            + "evidence, for 1 more fix round of about \(round) s"
            + (cutoffAt.map {
              ", which ends \(Int($0.timeIntervalSince(now)) - round) s before the cutoff"
            } ?? ""))
      }
      return NoRepairDecision(
        action: .continue, rows: rows,
        why: "\(shown), and 1 more fix round of about \(round) s would end after the cutoff at "
          + "\(stamp(cutoffAt)): the task stays blocked, never merged with the defect")
    }
    if case .contractGap(let name) = noRepair.cause {
      let proof = (left.reduce(0) { $0 + max(0, $1.milliseconds) } + 999) / 1000
      let fix = fixRound?.seconds ?? max(0, runSeconds)
      let round = proof + fix
      let fits = cutoffAt.map { now.addingTimeInterval(TimeInterval(round)) <= $0 } ?? true
      if fits {
        return NoRepairDecision(
          action: .amendContract, rows: rows,
          why: "\(named) needs a contract name the app doesn't have"
            + (name.map { " (`\($0)`)" } ?? "")
            + ": \(Self.amendmentPath). The repair's proof (\(proof) s) and 1 more fix round ("
            + (fixRound.map(\.described) ?? "\(fix) s, priced as the red run")
            + ") take about \(round) s"
            + (cutoffAt.map {
              ", which ends \(Int($0.timeIntervalSince(now)) - round) s before the cutoff"
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
          + ", with too little time to add it before the cutoff"
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

import Foundation

/// What a build worker hands back for one task (spec §5.3), checked by `build check-return`
/// against git and the run store before anything is merged. Every key is required, `gate`,
/// `review` and `designConflict` may be `null`, and an unknown key or value fails decoding: a
/// worker can't claim anything the type doesn't name.
public struct TaskReturn: Sendable, Equatable {
  public enum Outcome: String, Sendable, Equatable, Codable, CaseIterable {
    case readyToMerge = "ready-to-merge"
    case gateRed = "gate-red"
    case reviewBlocked = "review-blocked"
    case designConflict = "design-conflict"

    /// Outcomes that only follow a green task gate.
    public var claimsGreenGate: Bool { self == .readyToMerge || self == .reviewBlocked }
  }

  /// The one `swiftgate check` run the worker cites for its task gate.
  public struct Gate: Sendable, Equatable {
    public let tier: CheckTier
    public let verdict: Verdict
    public let runID: String

    public init(tier: CheckTier, verdict: Verdict, runID: String) {
      self.tier = tier
      self.verdict = verdict
      self.runID = runID
    }
  }

  /// The review stage's result: its findings are the Foundation review contract's.
  public struct Review: Sendable, Equatable {
    public let mode: BuildPreset.Review
    public let findings: [ReviewFinding]

    public init(mode: BuildPreset.Review, findings: [ReviewFinding]) {
      self.mode = mode
      self.findings = findings
    }
  }

  public let task: String
  public let outcome: Outcome
  public let commits: [String]
  /// `nil` when no gate ran, which only a `design-conflict` return may say.
  public let gate: Gate?
  /// `nil` when no review ran.
  public let review: Review?
  public let testsAdded: [String]
  public let notes: String
  public let designConflict: TaskStatusReport.Report?

  public init(
    task: String, outcome: Outcome, commits: [String], gate: Gate?, review: Review?,
    testsAdded: [String], notes: String, designConflict: TaskStatusReport.Report?
  ) {
    self.task = task
    self.outcome = outcome
    self.commits = commits
    self.gate = gate
    self.review = review
    self.testsAdded = testsAdded
    self.notes = notes
    self.designConflict = designConflict
  }
}

/// Why a task return failed to decode: the key it lacks or the key it shouldn't have.
public enum TaskReturnDecodingError: Error, Sendable, Equatable, CustomStringConvertible {
  case missingKey(String)
  case unknownKeys([String])

  public var description: String {
    switch self {
    case .missingKey(let key): "missing key `\(key)`"
    case .unknownKeys(let keys): "unknown keys: \(keys.joined(separator: ", "))"
    }
  }
}

/// Decodes one object's keys strictly: each of `expected` must be present (a `null` counts), and
/// nothing else may be.
private struct StrictKeys {
  private struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
  }

  static func check(_ decoder: any Decoder, expected: [String]) throws {
    let present = Set(try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue))
    let unknown = present.subtracting(expected).sorted()
    if !unknown.isEmpty { throw TaskReturnDecodingError.unknownKeys(unknown) }
    if let missing = expected.first(where: { !present.contains($0) }) {
      throw TaskReturnDecodingError.missingKey(missing)
    }
  }
}

extension BuildPreset.Review: Codable {}

extension TaskReturn.Gate: Codable {
  private enum CodingKeys: String, CodingKey, CaseIterable {
    case tier, verdict
    case runID = "runId"
  }

  public init(from decoder: any Decoder) throws {
    try StrictKeys.check(decoder, expected: CodingKeys.allCases.map(\.stringValue))
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      tier: try c.decode(CheckTier.self, forKey: .tier),
      verdict: try c.decode(Verdict.self, forKey: .verdict),
      runID: try c.decode(String.self, forKey: .runID))
  }
}

extension TaskReturn.Review: Codable {
  private enum CodingKeys: String, CodingKey, CaseIterable {
    case mode, findings
  }

  public init(from decoder: any Decoder) throws {
    try StrictKeys.check(decoder, expected: CodingKeys.allCases.map(\.stringValue))
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      mode: try c.decode(BuildPreset.Review.self, forKey: .mode),
      findings: try c.decode([ReviewFinding].self, forKey: .findings))
  }
}

extension TaskReturn: Codable {
  private enum CodingKeys: String, CodingKey, CaseIterable {
    case task, outcome, commits, gate, review, testsAdded, notes, designConflict
  }

  public init(from decoder: any Decoder) throws {
    try StrictKeys.check(decoder, expected: CodingKeys.allCases.map(\.stringValue))
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      task: try c.decode(String.self, forKey: .task),
      outcome: try c.decode(Outcome.self, forKey: .outcome),
      commits: try c.decode([String].self, forKey: .commits),
      gate: try c.decodeIfPresent(Gate.self, forKey: .gate),
      review: try c.decodeIfPresent(Review.self, forKey: .review),
      testsAdded: try c.decode([String].self, forKey: .testsAdded),
      notes: try c.decode(String.self, forKey: .notes),
      designConflict: try c.decodeIfPresent(TaskStatusReport.Report.self, forKey: .designConflict))
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(task, forKey: .task)
    try c.encode(outcome, forKey: .outcome)
    try c.encode(commits, forKey: .commits)
    try c.encode(gate, forKey: .gate)
    try c.encode(review, forKey: .review)
    try c.encode(testsAdded, forKey: .testsAdded)
    try c.encode(notes, forKey: .notes)
    try c.encode(designConflict, forKey: .designConflict)
  }
}

public enum TaskReturnJSON {
  public static func decode(_ data: Data) throws -> TaskReturn {
    try JSONDecoder().decode(TaskReturn.self, from: data)
  }

  public static func encode(_ taskReturn: TaskReturn) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(taskReturn)
  }
}

/// One way a task return claims more than git, the run store or the worktree shows.
public struct TaskReturnFinding: Sendable, Equatable, Encodable {
  public enum Rule: String, Sendable, Equatable, Encodable, CaseIterable {
    case branchMissing = "build-return.branch-missing"
    case noCommits = "build-return.no-commits"
    case commitMissing = "build-return.commit-missing"
    case commitOffBranch = "build-return.commit-off-branch"
    case gateMissing = "build-return.gate-missing"
    case gateRunMissing = "build-return.gate-run-missing"
    case gateVerdictMismatch = "build-return.gate-verdict-mismatch"
    case gateTierMismatch = "build-return.gate-tier-mismatch"
    case gateNotGreen = "build-return.gate-not-green"
    case gateBelowTaskGate = "build-return.gate-below-task-gate"
    case gateRedOutcomeIsGreen = "build-return.gate-red-outcome-is-green"
    case reviewMissing = "build-return.review-missing"
    case designConflictOutcome = "build-return.design-conflict-outcome"
    case designConflictUnrecorded = "build-return.design-conflict-unrecorded"
    case designConflictUnreturned = "build-return.design-conflict-unreturned"
    case designConflictMismatch = "build-return.design-conflict-mismatch"
    case outsideWriteSetUnexplained = "build-return.outside-write-set-unexplained"
  }

  public let rule: Rule
  public let message: String

  public init(rule: Rule, message: String) {
    self.rule = rule
    self.message = message
  }
}

/// What git, the task worktree's run store and its `task-status.json` show, gathered by the
/// caller so the check itself stays pure.
public struct TaskReturnEvidence: Sendable, Equatable {
  public enum CommitState: Sendable, Equatable {
    case missing
    case offBranch
    case onBranch
  }

  /// The run the return's `gate.runId` names, from the task worktree's run history.
  public struct GateRun: Sendable, Equatable {
    /// `nil` when the run wasn't a `swiftgate check --tier` run.
    public let tier: CheckTier?
    public let verdict: Verdict

    public init(tier: CheckTier?, verdict: Verdict) {
      self.tier = tier
      self.verdict = verdict
    }

    /// The tier of a run history `command` such as `check push`; `nil` for any other command.
    public static func tier(ofCommand command: String?) -> CheckTier? {
      guard let command, command.hasPrefix("check ") else { return nil }
      return CheckTier(rawValue: String(command.dropFirst("check ".count)))
    }
  }

  public let branch: String
  public let branchExists: Bool
  /// Keyed by each commit exactly as the return names it.
  public let commits: [String: CommitState]
  /// `nil` when the return names no gate run or the run store has none by that id.
  public let gateRun: GateRun?
  /// The tier the task had to pass: the preset's fixed tier, or the ledger's when it defers.
  public let taskGate: CheckTier
  /// The worktree's `task-status.json`, when it exists.
  public let taskStatus: TaskStatusReport?
  /// Files the task branch changed since it left `main` that no write-set entry covers.
  public let filesOutsideWriteSet: [String]

  public init(
    branch: String, branchExists: Bool, commits: [String: CommitState], gateRun: GateRun?,
    taskGate: CheckTier, taskStatus: TaskStatusReport?, filesOutsideWriteSet: [String] = []
  ) {
    self.branch = branch
    self.branchExists = branchExists
    self.commits = commits
    self.gateRun = gateRun
    self.taskGate = taskGate
    self.taskStatus = taskStatus
    self.filesOutsideWriteSet = filesOutsideWriteSet
  }
}

/// Spec §5.3: a return that claims more than git and the run store show fails. Re-runs nothing.
public enum TaskReturnCheck {
  public static let designConflictKind = "design-conflict"

  /// `fast` < `push` < `ready`: each tier runs everything the one before it does.
  public static func covers(_ tier: CheckTier, _ required: CheckTier) -> Bool {
    let order = CheckTier.allCases
    return (order.firstIndex(of: tier) ?? 0) >= (order.firstIndex(of: required) ?? 0)
  }

  public static func findings(_ taskReturn: TaskReturn, evidence: TaskReturnEvidence)
    -> [TaskReturnFinding]
  {
    commitFindings(taskReturn, evidence) + gateFindings(taskReturn, evidence)
      + reviewFindings(taskReturn) + designConflictFindings(taskReturn, evidence)
      + writeSetFindings(taskReturn, evidence)
  }

  /// The worker may make a small edit outside its write set when it names the file in `notes`
  /// (the build-worker contract). An edit the notes never name is a finding.
  private static func writeSetFindings(_ taskReturn: TaskReturn, _ evidence: TaskReturnEvidence)
    -> [TaskReturnFinding]
  {
    let unexplained = evidence.filesOutsideWriteSet.filter { !taskReturn.notes.contains($0) }
    guard !unexplained.isEmpty else { return [] }
    return [
      .init(
        rule: .outsideWriteSetUnexplained,
        message:
          "the task branch changed \(unexplained.joined(separator: ", ")) outside its write set, "
          + "and the return's notes never name it")
    ]
  }

  private static func commitFindings(_ taskReturn: TaskReturn, _ evidence: TaskReturnEvidence)
    -> [TaskReturnFinding]
  {
    var findings: [TaskReturnFinding] = []
    if taskReturn.outcome == .readyToMerge, taskReturn.commits.isEmpty {
      findings.append(.init(rule: .noCommits, message: "a ready-to-merge return names no commits"))
    }
    guard evidence.branchExists else {
      if !taskReturn.commits.isEmpty {
        findings.append(
          .init(rule: .branchMissing, message: "branch \(evidence.branch) doesn't exist"))
      }
      return findings
    }
    for commit in taskReturn.commits {
      switch evidence.commits[commit] ?? .missing {
      case .missing:
        findings.append(
          .init(rule: .commitMissing, message: "commit \(commit) doesn't exist in this repository"))
      case .offBranch:
        findings.append(
          .init(
            rule: .commitOffBranch,
            message: "commit \(commit) isn't reachable from branch \(evidence.branch)"))
      case .onBranch:
        break
      }
    }
    return findings
  }

  private static func gateFindings(_ taskReturn: TaskReturn, _ evidence: TaskReturnEvidence)
    -> [TaskReturnFinding]
  {
    guard let gate = taskReturn.gate else {
      if taskReturn.outcome == .designConflict { return [] }
      return [
        .init(
          rule: .gateMissing,
          message: "a \(taskReturn.outcome.rawValue) return must name the gate run it cites")
      ]
    }
    guard let run = evidence.gateRun else {
      return [
        .init(
          rule: .gateRunMissing,
          message: "gate run \(gate.runID) isn't in the task worktree's run history")
      ]
    }
    var findings: [TaskReturnFinding] = []
    if run.verdict != gate.verdict {
      findings.append(
        .init(
          rule: .gateVerdictMismatch,
          message:
            "gate run \(gate.runID) is \(run.verdict.rawValue), not \(gate.verdict.rawValue)"))
    }
    if run.tier != gate.tier {
      findings.append(
        .init(
          rule: .gateTierMismatch,
          message: "gate run \(gate.runID) was "
            + (run.tier.map { "check --tier \($0.rawValue)" } ?? "not a `check --tier` run")
            + ", not check --tier \(gate.tier.rawValue)"))
    }
    if taskReturn.outcome.claimsGreenGate {
      if run.verdict != .green {
        findings.append(
          .init(
            rule: .gateNotGreen,
            message:
              "a \(taskReturn.outcome.rawValue) return needs a GREEN gate; run \(gate.runID) is "
              + run.verdict.rawValue))
      }
      if !(run.tier.map { covers($0, evidence.taskGate) } ?? false) {
        findings.append(
          .init(
            rule: .gateBelowTaskGate,
            message: "gate run \(gate.runID) is below the task gate `\(evidence.taskGate.rawValue)`"
          ))
      }
    }
    if taskReturn.outcome == .gateRed, run.verdict == .green {
      findings.append(
        .init(
          rule: .gateRedOutcomeIsGreen,
          message: "a gate-red return cites gate run \(gate.runID), which is GREEN"))
    }
    return findings
  }

  private static func reviewFindings(_ taskReturn: TaskReturn) -> [TaskReturnFinding] {
    guard taskReturn.outcome.claimsGreenGate, taskReturn.review == nil else { return [] }
    return [
      .init(
        rule: .reviewMissing,
        message: "a \(taskReturn.outcome.rawValue) return must carry the review it passed through")
    ]
  }

  private static func designConflictFindings(
    _ taskReturn: TaskReturn, _ evidence: TaskReturnEvidence
  ) -> [TaskReturnFinding] {
    var findings: [TaskReturnFinding] = []
    let isConflictOutcome = taskReturn.outcome == .designConflict
    if isConflictOutcome != (taskReturn.designConflict != nil) {
      findings.append(
        .init(
          rule: .designConflictOutcome,
          message: isConflictOutcome
            ? "a design-conflict return must carry its designConflict report"
            : "a \(taskReturn.outcome.rawValue) return carries a designConflict report"))
    }
    let recorded = evidence.taskStatus.flatMap { status in
      status.report.kind == designConflictKind ? status : nil
    }
    switch (taskReturn.designConflict, recorded) {
    case (nil, nil):
      break
    case (.some, nil):
      findings.append(
        .init(
          rule: .designConflictUnrecorded,
          message:
            "the return reports a design conflict, but the task worktree's "
            + ".harness/task-status.json holds no design-conflict report"))
    case (nil, .some):
      findings.append(
        .init(
          rule: .designConflictUnreturned,
          message:
            "the task worktree's .harness/task-status.json reports a design conflict the return leaves out"
        ))
    case (.some(let returned), .some(let status)):
      if returned != status.report || status.task != taskReturn.task {
        findings.append(
          .init(
            rule: .designConflictMismatch,
            message:
              "the return's designConflict differs from the task worktree's .harness/task-status.json"
          ))
      }
    }
    return findings
  }
}

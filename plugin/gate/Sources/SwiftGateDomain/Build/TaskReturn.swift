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
  /// The task's first commit when it adds API: declarations with unimplemented bodies and no
  /// tests, the ancestor its gate's `prove` retries compile-only tests at. `nil` when the task
  /// adds no API another test calls.
  public let surfaceCommit: String?

  public init(
    task: String, outcome: Outcome, commits: [String], gate: Gate?, review: Review?,
    testsAdded: [String], notes: String, designConflict: TaskStatusReport.Report?,
    surfaceCommit: String? = nil
  ) {
    self.task = task
    self.outcome = outcome
    self.commits = commits
    self.gate = gate
    self.review = review
    self.testsAdded = testsAdded
    self.notes = notes
    self.designConflict = designConflict
    self.surfaceCommit = surfaceCommit
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
    case task, outcome, commits, gate, review, testsAdded, notes, designConflict, surfaceCommit
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
      designConflict: try c.decodeIfPresent(TaskStatusReport.Report.self, forKey: .designConflict),
      surfaceCommit: try c.decodeIfPresent(String.self, forKey: .surfaceCommit))
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
    try c.encode(surfaceCommit, forKey: .surfaceCommit)
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
    case outsideWriteSet = "build-return.outside-write-set"
    case gateMissingProof = "build-return.gate-missing-proof"
    case surfaceCommitOffBranch = "build-return.surface-commit-off-branch"
    case surfaceCommitNotProofBase = "build-return.surface-commit-not-proof-base"
    case outsideWriteSetUnexplained = "build-return.outside-write-set-unexplained"
    case gateMissingStep = "build-return.gate-missing-step"
    case targetOutsideSurface = "build-return.target-outside-surface"
    case testNeedsStub = "build-return.test-needs-stub"
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
    /// `ready` steps the run added below `ready`, such as `prove` and `mutate`.
    public let steps: [String]
    /// The refs its `prove` retried compile-only tests at.
    public let proofBases: [String]

    public init(
      tier: CheckTier?, verdict: Verdict, steps: [String] = [], proofBases: [String] = []
    ) {
      self.tier = tier
      self.verdict = verdict
      self.steps = steps
      self.proofBases = proofBases
    }

    /// Whether the run proved and mutated the change: `ready` always does, a lower tier only
    /// when asked.
    public var provedAndMutated: Bool {
      tier == .ready || Set(steps).isSuperset(of: ["prove", "mutate"])
    }

    /// The steps of `required` this run never ran: its tier doesn't run them and its recorded
    /// steps don't name them. A run that isn't a `check --tier` run ran none of them.
    public func missingSteps(of required: [CheckExtraStep]) -> [CheckExtraStep] {
      guard let tier else { return required }
      return required.filter { !$0.isRun(by: tier) && !steps.contains($0.rawValue) }
    }

    /// The run a run history line records.
    public init(record: RunHistoryRecord) {
      self.init(
        tier: Self.tier(ofCommand: record.command), verdict: record.verdict,
        steps: record.steps ?? [], proofBases: record.proofBases ?? [])
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
  /// A fixer resolves a collision with another task's files, so a file its notes name is allowed;
  /// a worker gets no such allowance.
  public let explainedEditsAllowed: Bool
  /// A worker's green gate must prove and mutate its change; a fixer's merge gate need not.
  public let proofRequired: Bool
  /// A worker's green return must carry its review; a fixer's never does, since no review stage
  /// runs on the fix path.
  public let reviewRequired: Bool
  /// Where the return's `surfaceCommit` is, when it names one.
  public let surfaceCommit: CommitState?
  /// A worker's green gate must run every one of ``TaskReturnCheck/taskGateSteps``, under either
  /// `task_proof`; a fixer's merge gate need not.
  public let taskGateStepsRequired: Bool
  /// The manifests the task branch changed, read at the plan's surface commit and at the branch
  /// tip. `nil` when the plan has no surface commit.
  public let planSurface: PlanSurfaceManifests?
  /// The task branch's new and changed host tests, built at the plan's proof bases. `nil` when
  /// the plan has no surface commit or the branch changes no host test.
  public let testBuild: ProofBaseTestBuild?

  public init(
    branch: String, branchExists: Bool, commits: [String: CommitState], gateRun: GateRun?,
    taskGate: CheckTier, taskStatus: TaskStatusReport?, filesOutsideWriteSet: [String] = [],
    explainedEditsAllowed: Bool = false, proofRequired: Bool = false,
    surfaceCommit: CommitState? = nil, reviewRequired: Bool = true,
    taskGateStepsRequired: Bool, planSurface: PlanSurfaceManifests? = nil,
    testBuild: ProofBaseTestBuild? = nil
  ) {
    self.branch = branch
    self.branchExists = branchExists
    self.commits = commits
    self.gateRun = gateRun
    self.taskGate = taskGate
    self.taskStatus = taskStatus
    self.filesOutsideWriteSet = filesOutsideWriteSet
    self.explainedEditsAllowed = explainedEditsAllowed
    self.proofRequired = proofRequired
    self.reviewRequired = reviewRequired
    self.surfaceCommit = surfaceCommit
    self.taskGateStepsRequired = taskGateStepsRequired
    self.planSurface = planSurface
    self.testBuild = testBuild
  }
}

/// A task branch's new and changed host tests, built with the production source it changed
/// reverted to each proof base in turn: the plan surface, each merged task's stub, then the
/// return's own stub. The final gate's `prove` reverts the same way, so a test that compiles at
/// none of them is one it can only judge compile-only.
public struct ProofBaseTestBuild: Sendable, Equatable {
  /// A test file the compiler rejected at the last proof base tried, with its first error there.
  public struct UncompiledFile: Sendable, Equatable {
    public let file: String
    public let error: String

    public init(file: String, error: String) {
      self.file = file
      self.error = error
    }
  }

  /// How one package's build at one proof base went.
  public enum Outcome: Sendable, Equatable {
    /// The tests compiled, whatever they then did.
    case compiled
    /// The compiler rejected these test files.
    case testsDontCompile([UncompiledFile])
    /// The build says nothing about the tests: it failed outside them, or left no evidence.
    case noEvidence(String)
  }

  /// The refs production source was reverted to, oldest first.
  public let proofBases: [String]
  public let uncompiled: [UncompiledFile]

  public init(proofBases: [String], uncompiled: [UncompiledFile]) {
    self.proofBases = proofBases
    self.uncompiled = uncompiled
  }

  /// - Parameter testDirectories: the package's test target directories; a compile error
  ///   outside them means the reverted tree itself doesn't build.
  public static func outcome(of run: SelectedTestRun, testDirectories: [String]) -> Outcome {
    switch run {
    case .reported, .crashed:
      return .compiled
    case .noEvidence(let reason):
      return .noEvidence(reason)
    case .buildFailed(let errors):
      if let outside = errors.first(where: { error in
        !testDirectories.contains { error.file == $0 || error.file.hasPrefix($0 + "/") }
      }) {
        return .noEvidence("the code under test doesn't build: \(located(outside))")
      }
      var files: [UncompiledFile] = []
      for error in errors where !files.contains(where: { $0.file == error.file }) {
        files.append(UncompiledFile(file: error.file, error: located(error)))
      }
      return files.isEmpty
        ? .noEvidence("the build failed and named no error") : .testsDontCompile(files)
    }
  }

  private static func located(_ error: Finding) -> String {
    (error.line.map { "\(error.file):\($0)" } ?? error.file) + ": \(error.message)"
  }
}

/// Every `Package.swift` a task branch changed, as the plan's surface commit and the branch tip
/// each hold it.
public struct PlanSurfaceManifests: Sendable, Equatable {
  /// The plan's surface commit.
  public let surface: String
  /// `atSurface` is the manifest at ``surface``; `atHead` is the manifest at the branch tip.
  public let manifests: [SliceManifest]

  public init(surface: String, manifests: [SliceManifest]) {
    self.surface = surface
    self.manifests = manifests
  }
}

/// Spec §5.3: a return that claims more than git and the run store show fails. Re-runs nothing.
public enum TaskReturnCheck {
  public static let designConflictKind = "design-conflict"
  /// The steps the build task workflow's gate adds to every worker's task gate, in the order its
  /// flags are named.
  public static let taskGateSteps: [CheckExtraStep] = [.impact, .coverage, .appBuild]

  /// The steps a worker's gate at `tier` must show it ran.
  public static func requiredSteps(at tier: CheckTier) -> [CheckExtraStep] {
    taskGateSteps
  }

  /// `fast` < `push` < `ready`, and `slice` < `merge` < `final`: each tier runs everything the
  /// one before it does. No tier covers one of the other profile.
  public static func covers(_ tier: CheckTier, _ required: CheckTier) -> Bool {
    tier.profile == required.profile && tier.strength >= required.strength
  }

  public static func findings(_ taskReturn: TaskReturn, evidence: TaskReturnEvidence)
    -> [TaskReturnFinding]
  {
    commitFindings(taskReturn, evidence) + gateFindings(taskReturn, evidence)
      + reviewFindings(taskReturn, evidence) + designConflictFindings(taskReturn, evidence)
      + writeSetFindings(taskReturn, evidence) + surfaceFindings(taskReturn, evidence)
      + manifestFindings(evidence) + testBuildFindings(evidence)
  }

  /// A test the task adds or changes must compile at the proof bases the final gate's `prove`
  /// retries it at, or that gate can only judge it compile-only, after the task has merged.
  private static func testBuildFindings(_ evidence: TaskReturnEvidence) -> [TaskReturnFinding] {
    guard let build = evidence.testBuild else { return [] }
    let bases = build.proofBases.joined(separator: ", ")
    return build.uncompiled.map { file in
      TaskReturnFinding(
        rule: .testNeedsStub,
        message:
          "\(file.file) doesn't compile with the task's production source reverted to the proof "
          + "bases (\(bases)): \(file.error). It calls API none of them declares, so the final "
          + "gate's prove can only judge it compile-only. Commit that API alone as a stub (bodies "
          + "that do nothing yet), check it with `swiftgate surface-check <stub sha>`, prove at it "
          + "with `--proof-base <stub sha>`, and return it as `surfaceCommit`")
    }
  }

  /// A task may fill the targets the plan surface declares but never declare one: at the surface
  /// a new target has no sources, so SwiftPM refuses its package and the final gate's `prove`
  /// can't build a test in it or a dependent. 1 finding per manifest.
  private static func manifestFindings(_ evidence: TaskReturnEvidence) -> [TaskReturnFinding] {
    guard let planSurface = evidence.planSurface else { return [] }
    let surface = planSurface.surface
    return planSurface.manifests.sorted { $0.path < $1.path }.flatMap { manifest in
      SliceManifestCheck.findings([manifest]).map { finding in
        let message: String
        switch finding {
        case .undeclared(let path, let targets, let products):
          let named = joined(targets.map { "target \($0)" } + products.map { "product \($0)" })
          message =
            (manifest.atSurface == nil
              ? "\(path) is a package the plan surface \(surface) lacks; it adds \(named)"
              : "\(path) adds \(named), which the plan surface \(surface) doesn't declare")
            + ". At the surface a new target has no sources, so SwiftPM refuses its package and "
            + "the final gate's prove can't build a test in it or a dependent. The surface needs "
            + "a stub target for each: return a design conflict (section `surface`) instead of "
            + "declaring it on the task branch"
        case .unreadable(let path, let side, let reason):
          message =
            "\(path) can't be read at "
            + (side == .surface ? "the plan surface \(surface)" : "the task branch tip")
            + " (\(reason)). Write its targets and products as `.target(name: \"…\")`-style "
            + "elements of the `targets:` and `products:` arrays in its `Package(…)` call"
        }
        return TaskReturnFinding(rule: .targetOutsideSurface, message: message)
      }
    }
  }

  /// `a`, `a and b`, `a, b and c`.
  private static func joined(_ items: [String]) -> String {
    guard let last = items.last, items.count > 1 else { return items.first ?? "" }
    return items.dropLast().joined(separator: ", ") + " and " + last
  }

  /// A surface commit must be on the task branch and, when the gate had to prove the change, be
  /// one of its proof bases, or the proof it stands for never ran. A gate that needn't prove has
  /// no proof base to check.
  private static func surfaceFindings(_ taskReturn: TaskReturn, _ evidence: TaskReturnEvidence)
    -> [TaskReturnFinding]
  {
    guard let surface = taskReturn.surfaceCommit else { return [] }
    guard evidence.surfaceCommit == .onBranch else {
      return [
        .init(
          rule: .surfaceCommitOffBranch,
          message: "surface commit \(surface) isn't on branch \(evidence.branch)")
      ]
    }
    guard evidence.proofRequired, let run = evidence.gateRun, let gate = taskReturn.gate else {
      return []
    }
    let isProofBase = run.proofBases.contains { $0.hasPrefix(surface) || surface.hasPrefix($0) }
    guard !isProofBase else { return [] }
    return [
      .init(
        rule: .surfaceCommitNotProofBase,
        message:
          "gate run \(gate.runID) never proved at surface commit \(surface); run "
          + "`swiftgate check --proof-base \(surface)`")
    ]
  }

  /// A worker's edit outside its write set is a finding: a task that needs one is a design
  /// conflict. A fixer's edit passes when its notes name the file.
  private static func writeSetFindings(_ taskReturn: TaskReturn, _ evidence: TaskReturnEvidence)
    -> [TaskReturnFinding]
  {
    guard evidence.explainedEditsAllowed else {
      guard !evidence.filesOutsideWriteSet.isEmpty else { return [] }
      return [
        .init(
          rule: .outsideWriteSet,
          message:
            "the task branch changed \(evidence.filesOutsideWriteSet.joined(separator: ", ")) "
            + "outside its write set; a task that needs that edit returns a design conflict")
      ]
    }
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
      if evidence.proofRequired, !run.provedAndMutated {
        findings.append(
          .init(
            rule: .gateMissingProof,
            message:
              "gate run \(gate.runID) ran neither prove nor mutate over the change; a task gate "
              + "runs `swiftgate check --tier <task gate> --base main --prove --mutate`"))
      }
      if evidence.taskGateStepsRequired {
        findings += run.missingSteps(of: requiredSteps(at: evidence.taskGate)).map { step in
          .init(
            rule: .gateMissingStep,
            message:
              "gate run \(gate.runID) never ran the task gate's `\(step.rawValue)` step; a task "
              + "gate runs `swiftgate check --tier <task gate> --base main --\(step.rawValue)`")
        }
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

  private static func reviewFindings(_ taskReturn: TaskReturn, _ evidence: TaskReturnEvidence)
    -> [TaskReturnFinding]
  {
    guard evidence.reviewRequired, taskReturn.outcome.claimsGreenGate, taskReturn.review == nil
    else { return [] }
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
            + "\(RunLayout.taskStatusFile) holds no design-conflict report"))
    case (nil, .some):
      findings.append(
        .init(
          rule: .designConflictUnreturned,
          message:
            "the task worktree's \(RunLayout.taskStatusFile) reports a design conflict the return leaves out"
        ))
    case (.some(let returned), .some(let status)):
      if returned != status.report || status.task != taskReturn.task {
        findings.append(
          .init(
            rule: .designConflictMismatch,
            message:
              "the return's designConflict differs from the task worktree's \(RunLayout.taskStatusFile)"
          ))
      }
    }
    return findings
  }
}

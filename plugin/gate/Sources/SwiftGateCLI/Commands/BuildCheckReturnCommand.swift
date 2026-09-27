import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// What `build check-return` found in one task return.
struct BuildCheckReturnReport: Sendable, Equatable, Encodable {
  let command: String
  let plan: String?
  let task: String?
  /// GREEN: every claim holds. RED: at least one finding. BLOCKED: the return or the state it's
  /// checked against couldn't be read.
  let verdict: Verdict
  let findings: [TaskReturnFinding]
  /// Sources read with a degradation the verdict doesn't show, such as unreadable history lines.
  let warnings: [String]
  let message: String
}

/// The testable core of `build check-return` (spec §5.3). Reads the return, the plan's ledger and
/// newest build run, git, and the task worktree's run store and `task-status.json`; writes
/// nothing and re-runs nothing. The judgement itself is ``TaskReturnCheck``.
enum BuildCheckReturnRun {
  static let command = "build check-return"
  static let taskStatusFile = ".harness/task-status.json"

  private struct Blocked: Error {
    let message: String
    init(_ message: String) { self.message = message }
  }

  /// - Parameter fix: check a fixer's return: its commits are on `<plan>/fix-<task>`, its gate
  ///   run is in the fix worktree, and the tier to meet is the run preset's merge gate.
  static func run(file: String, plan: String?, fix: Bool = false, git: any Git) async
    -> BuildCheckReturnReport
  {
    let blocked = { (task: String?, message: String) in
      BuildCheckReturnReport(
        command: command, plan: plan, task: task, verdict: .blocked, findings: [], warnings: [],
        message: message)
    }
    let taskReturn: TaskReturn
    do {
      taskReturn = try TaskReturnJSON.decode(try Data(contentsOf: URL(filePath: file)))
    } catch let error as DecodingError {
      return blocked(nil, "\(file) isn't a task return: \(describe(error))")
    } catch {
      return blocked(nil, "\(file) isn't a task return: \(error)")
    }
    guard let plan else {
      return blocked(taskReturn.task, "--plan is required: the slug of the task's plan")
    }
    do throws(Blocked) {
      var warnings: [String] = []
      let evidence = try await gather(
        taskReturn, plan: plan, fix: fix, git: git, warnings: &warnings)
      let findings = TaskReturnCheck.findings(taskReturn, evidence: evidence)
      return BuildCheckReturnReport(
        command: command, plan: plan, task: taskReturn.task,
        verdict: findings.isEmpty ? .green : .red, findings: findings, warnings: warnings,
        message: findings.isEmpty
          ? "task `\(taskReturn.task)`: the return matches git and the run store"
          : "task `\(taskReturn.task)`: \(findings.count) claim(s) the evidence doesn't support")
    } catch {
      return blocked(taskReturn.task, error.message)
    }
  }

  private static func gather(
    _ taskReturn: TaskReturn, plan slug: String, fix: Bool, git: any Git,
    warnings: inout [String]
  ) async throws(Blocked) -> TaskReturnEvidence {
    let store: PlanStateStore
    do throws(PlanStateStoreError) {
      store = try await PlanStateStore.locate(slug: slug, git: git)
    } catch {
      throw Blocked("can't locate plan `\(slug)`: \(error)")
    }
    let ledger: Ledger
    do throws(PlanStateStoreError) {
      ledger = try store.ledger()
    } catch {
      throw Blocked("\(error)")
    }
    guard let task = ledger.tasks.first(where: { $0.id == taskReturn.task }) else {
      throw Blocked("plan `\(slug)` has no task `\(taskReturn.task)`")
    }
    let (taskGate, taskProof) = try await taskGate(
      of: task, plan: store.plan, slug: slug, fix: fix, git: git)
    let names: TaskWorktree
    do {
      names = try TaskWorktree(
        commonDirectory: try await git.commonDirectory(), plan: slug,
        task: fix ? "fix-\(task.id)" : task.id)
    } catch {
      throw Blocked("can't name task `\(task.id)`'s worktree: \(error)")
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: names.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw Blocked("task `\(task.id)` has no worktree at \(names.path)")
    }
    let worktree = URL(filePath: names.path, directoryHint: .isDirectory)
    let branchRef = "refs/heads/\(names.branch)"
    let branchTip: String?
    do {
      branchTip = try await git.revision(branchRef)
    } catch {
      throw Blocked("reading branch \(names.branch): \(error)")
    }
    var commits: [String: TaskReturnEvidence.CommitState] = [:]
    var outside: [String] = []
    var surface: TaskReturnEvidence.CommitState?
    if let branchTip {
      for commit in taskReturn.commits {
        commits[commit] = try await state(of: commit, onBranchAt: branchTip, git: git)
      }
      if let surfaceCommit = taskReturn.surfaceCommit {
        surface = try await state(of: surfaceCommit, onBranchAt: branchTip, git: git)
      }
      outside = WriteSet.outside(
        try await branchChanges(tip: branchTip, git: git), writeSet: task.writeSet)
      if !outside.isEmpty {
        warnings.append(
          "the task branch changed \(outside.count) file(s) outside its write set: "
            + outside.joined(separator: ", "))
      }
    }
    return TaskReturnEvidence(
      branch: names.branch, branchExists: branchTip != nil, commits: commits,
      gateRun: try gateRun(taskReturn.gate, in: worktree, warnings: &warnings),
      taskGate: taskGate, taskStatus: try taskStatus(in: worktree), filesOutsideWriteSet: outside,
      explainedEditsAllowed: fix, proofRequired: !fix && taskProof == .perTask,
      surfaceCommit: surface)
  }

  /// Files the task branch changed since it forked from the checkout's `HEAD`, which is `main`
  /// when the orchestrator runs this.
  private static func branchChanges(tip: String, git: any Git) async throws(Blocked) -> [String] {
    do {
      guard let head = try await git.revision("HEAD"),
        let base = try await git.mergeBase(tip, head)
      else { return [] }
      return try await git.changedFiles(from: base, to: tip)
    } catch {
      throw Blocked("listing the task branch's changed files: \(error)")
    }
  }

  /// The preset's fixed tier, or the ledger's own when the preset defers to it. A fix is merged
  /// straight after, so it meets the preset's merge gate instead. Also the run preset's
  /// `taskProof`, which says whether the task gate had to prove and mutate.
  private static func taskGate(
    of task: LedgerTask, plan: PlanStateLayout.Plan, slug: String, fix: Bool, git: any Git
  ) async throws(Blocked) -> (CheckTier, BuildPreset.TaskProof) {
    let store: BuildRunStore?
    do {
      store = try await BuildRunStore.latest(plan: slug, git: git)
    } catch {
      throw Blocked("listing \(plan.buildDirectory): \(error)")
    }
    guard let store else { throw Blocked(LedgerSetRun.noBuildRun) }
    let record: BuildRunRecord
    do {
      record = try store.record()
    } catch {
      throw Blocked("reading build run \(store.runID): \(error)")
    }
    let proof = record.preset.taskProof
    if fix { return (record.preset.mergeGate, proof) }
    switch record.preset.taskGate {
    case .ledger: return (task.gate, proof)
    case .tier(let tier): return (tier, proof)
    }
  }

  /// A commit is only named by a hex object id; a ref or `<rev>~1` names whatever it points at
  /// today, not the work the worker committed.
  private static func state(of commit: String, onBranchAt tip: String, git: any Git)
    async throws(Blocked) -> TaskReturnEvidence.CommitState
  {
    let isHex =
      (4...64).contains(commit.utf8.count)
      && commit.utf8.allSatisfy {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
          || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
      }
    guard isHex else { return .missing }
    do {
      guard let full = try await git.revision(commit) else { return .missing }
      return try await git.mergeBase(full, tip) == full ? .onBranch : .offBranch
    } catch {
      throw Blocked("reading commit \(commit): \(error)")
    }
  }

  private static func gateRun(
    _ gate: TaskReturn.Gate?, in worktree: URL, warnings: inout [String]
  ) throws(Blocked) -> TaskReturnEvidence.GateRun? {
    guard let gate else { return nil }
    let store = RunStore(worktreeRoot: worktree)
    let history: (records: [RunHistoryRecord], invalidLines: Int)
    do {
      history = try store.readHistory()
    } catch {
      throw Blocked("reading \(store.historyFile.path): \(error)")
    }
    if history.invalidLines > 0 {
      warnings.append(
        "\(store.historyFile.path) has \(history.invalidLines) unreadable line(s), skipped")
    }
    guard let record = history.records.last(where: { $0.runID == gate.runID }) else {
      return nil
    }
    return TaskReturnEvidence.GateRun(
      tier: TaskReturnEvidence.GateRun.tier(ofCommand: record.command), verdict: record.verdict,
      steps: record.steps ?? [], proofBases: record.proofBases ?? [])
  }

  private static func taskStatus(in worktree: URL) throws(Blocked) -> TaskStatusReport? {
    let file = worktree.appending(path: taskStatusFile)
    let data: Data
    do {
      data = try Data(contentsOf: file)
    } catch CocoaError.fileReadNoSuchFile {
      return nil
    } catch {
      throw Blocked("reading \(file.path): \(error.localizedDescription)")
    }
    do {
      return try TaskStatusReportJSON.decode(data)
    } catch {
      throw Blocked("\(file.path) isn't a task status report: \(error)")
    }
  }

  /// Names the key and, for a bad value, what was there, so the worker can fix its return.
  private static func describe(_ error: DecodingError) -> String {
    switch error {
    case .dataCorrupted(let context), .typeMismatch(_, let context), .valueNotFound(_, let context):
      let path = context.codingPath.map(\.stringValue).joined(separator: ".")
      return path.isEmpty
        ? context.debugDescription : "`\(path)`: \(context.debugDescription)"
    case .keyNotFound(let key, _):
      return "missing key `\(key.stringValue)`"
    @unknown default:
      return "\(error)"
    }
  }

  static func render(_ report: BuildCheckReturnReport, format: OutputFormat) -> String {
    switch format {
    case .json:
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      let data = (try? encoder.encode(report)) ?? Data()
      return String(decoding: data, as: UTF8.self)
    case .human:
      let lines =
        ["\(report.command): \(report.verdict.rawValue) \(report.message)"]
        + report.findings.map { "  \($0.rule.rawValue): \($0.message)" }
        + report.warnings.map { "  warning: \($0)" }
      return lines.joined(separator: "\n")
    }
  }
}

struct BuildCheckReturnCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "check-return",
    abstract: "Check a task's return against git and the run store.",
    discussion:
      "Checks that each commit is on the task's branch <plan>/<task>, that the gate run is in "
      + "the task worktree's run history with the claimed tier and verdict (GREEN at the task "
      + "gate or above for ready-to-merge and review-blocked), and that designConflict matches "
      + "the worktree's .harness/task-status.json. Re-runs nothing and writes nothing. Exits 0 "
      + "when every claim holds, 1 for any finding, and 2 when the return or plan state can't "
      + "be read.")

  @Argument(help: "Path to the task's return JSON file.")
  var file: String

  @Option(help: "The slug of the plan the task belongs to.")
  var plan: String?

  @Option(
    help: ArgumentHelp(
      "The orchestrator's session id. Accepted so every build verb takes it; this check writes "
        + "nothing, so it isn't required."))
  var session: String?

  @Flag(
    help: ArgumentHelp(
      "Check a fixer's return: commits on <plan>/fix-<task>, the gate run in the fix worktree, "
        + "and the run preset's merge gate as the tier to meet."))
  var fix = false

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let git = LiveGit(runner: LiveProcessRunner(), repositoryRoot: root.path)
    let report = await BuildCheckReturnRun.run(file: file, plan: plan, fix: fix, git: git)
    Console.write(BuildCheckReturnRun.render(report, format: output.format))
    if report.verdict != .green { throw ExitCode(report.verdict.exitCode) }
  }
}

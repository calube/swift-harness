import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// A throwaway repository with a claimed plan, one build run, and the task's real worktree on
/// branch `<plan>/<task>` holding one commit. `main` carries a second branch, `elsewhere`, whose
/// commit never reaches the task branch.
private struct ReturnScenario {
  static let plan = "2026-09-26-queue"
  static let task = "queue-core"
  static let finishedAt = Date(timeIntervalSince1970: 1_790_000_000)

  let base: URL
  let main: URL
  let runner: LiveProcessRunner
  let git: LiveGit
  let worktree: URL
  let taskCommit: String
  let elsewhereCommit: String

  static func environment(home: URL) -> [String: String] {
    [
      "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin", "HOME": home.path,
      "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
      "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
      "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
    ]
  }

  /// - Parameters:
  ///   - ledgerGate: the task's planned gate in `ledger.json`.
  ///   - presetGate: the build run's task gate, which defers to the ledger when `.ledger`.
  ///   - taskProof: where the build run's preset proves and mutates each task's change.
  init(
    ledgerGate: CheckTier = .push, presetGate: BuildPreset.TaskGate = .ledger,
    taskProof: BuildPreset.TaskProof = .perTask
  ) async throws {
    base = TestTemporaryDirectory.root
      .appending(path: "check-return-\(UUID().uuidString)", directoryHint: .isDirectory)
    let main = base.appending(path: "app", directoryHint: .isDirectory)
    self.main = main
    try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
    let runner = LiveProcessRunner(baseEnvironment: Self.environment(home: base))
    self.runner = runner
    @discardableResult
    func run(_ arguments: [String], in directory: URL) async throws -> String {
      let output = try await runner.run(
        ProcessInvocation(
          executable: "git", arguments: arguments, workingDirectory: directory.path,
          timeout: .seconds(60)))
      try #require(output.status.isSuccess, "git \(arguments): \(output.stderr.text)")
      return output.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    try await run(["init", "-q", "-b", "main"], in: main)
    try await run(["config", "commit.gpgsign", "false"], in: main)
    try await run(["commit", "-q", "--allow-empty", "-m", "init"], in: main)
    try await run(["checkout", "-q", "-b", "elsewhere"], in: main)
    try await run(["commit", "-q", "--allow-empty", "-m", "unrelated work"], in: main)
    elsewhereCommit = try await run(["rev-parse", "HEAD"], in: main)
    try await run(["checkout", "-q", "main"], in: main)

    git = LiveGit(runner: runner, repositoryRoot: main.path)
    let common = try await git.commonDirectory()
    let names = try TaskWorktree(commonDirectory: common, plan: Self.plan, task: Self.task)
    try await run(["worktree", "add", "-q", "-b", names.branch, names.path, "main"], in: main)
    worktree = URL(filePath: names.path, directoryHint: .isDirectory)
    try await run(["commit", "-q", "--allow-empty", "-m", "task work"], in: worktree)
    taskCommit = try await run(["rev-parse", "HEAD"], in: worktree)

    let plan = try PlanStateLayout(commonDirectory: common).plan(Self.plan)
    try FileManager.default.createDirectory(
      atPath: plan.directory, withIntermediateDirectories: true)
    let task = LedgerTask(
      id: Self.task, deps: [], writeSet: ["Sources/Queue/"], gate: ledgerGate, tests: [],
      covers: ["D1"], estLines: 40, status: .inProgress, worktree: names.path, model: .sonnet,
      branch: names.branch)
    try LedgerJSON.encode(
      Ledger(
        schemaVersion: 1, resume: "building", maxParallel: 3, tasks: [task], waves: [[Self.task]])
    ).write(to: URL(filePath: plan.ledgerFile))
    let preset = BuildPreset(
      designTier: .standard, maxParallel: 3, review: .gate, taskGate: presetGate,
      mergeGate: .ready, workerModel: .tagged, timeBudgetMin: 90, stopStartsBeforeMin: 15,
      onDesignConflict: .block, taskProof: taskProof)
    try await BuildRunStore.create(
      plan: Self.plan, presetName: "default", preset: preset, startedAt: Self.finishedAt,
      git: git, suffix: 1)
  }

  /// Records a gate run in the task worktree's run store through the writer `check` uses. A
  /// worker's gate runs `prove`, `mutate` and the task gate's steps by default, as the worker
  /// contract asks, on a clean tree at the checkout's `HEAD` unless `head` names another commit.
  func recordGateRun(
    tier: CheckTier, verdict: Verdict, suffix: UInt32, in checkout: URL? = nil,
    steps: [String]? = ["prove", "mutate", "impact", "coverage", "app-build"],
    proofBases: [String]? = nil, head: String? = nil, dirty: Bool? = false
  ) async throws -> String {
    let runID = RunID.make(startedAt: Self.finishedAt, suffix: suffix)
    let report = try RunReport(
      runID: runID, durationMilliseconds: 1200,
      tiers: [TierResult(tier: .t1, verdict: verdict, durationMilliseconds: 1200, testCounts: nil)],
      findings: [])
    let checkout = checkout ?? worktree
    try RunStore(worktreeRoot: checkout).record(
      report, finishedAt: Self.finishedAt, command: "check \(tier.rawValue)", steps: steps,
      proofBases: proofBases, headCommit: try await resolved(head, in: checkout), dirty: dirty)
    return runID
  }

  /// `head`, or else `HEAD` of `checkout`, read as `check` reads it when a run starts.
  private func resolved(_ head: String?, in checkout: URL) async throws -> String {
    if let head { return head }
    return try #require(
      try await LiveGit(runner: runner, repositoryRoot: checkout.path).revision("HEAD"),
      "\(checkout.path) has no HEAD")
  }

  func returnValue(
    outcome: TaskReturn.Outcome = .readyToMerge, commits: [String]? = nil,
    gate: TaskReturn.Gate?, designConflict: TaskStatusReport.Report? = nil,
    notes: String = "Queue.drain() returns [Item]", surfaceCommit: String? = nil,
    review: TaskReturn.Review? = .init(mode: .gate, findings: [])
  ) -> TaskReturn {
    TaskReturn(
      task: Self.task, outcome: outcome, commits: commits ?? [taskCommit], gate: gate,
      review: review, testsAdded: ["test-queue-drains"],
      notes: notes, designConflict: designConflict, surfaceCommit: surfaceCommit)
  }

  /// Commits `paths` on the task branch and returns the commit.
  func commitFiles(_ paths: [String]) async throws -> String {
    for path in paths {
      let file = worktree.appending(path: path)
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("// \(path)\n".utf8).write(to: file)
    }
    try await inWorktree(["add", "--"] + paths)
    try await inWorktree(["commit", "-q", "-m", "task files"])
    return try await inWorktree(["rev-parse", "HEAD"])
  }

  @discardableResult
  private func inWorktree(_ arguments: [String]) async throws -> String {
    let output = try await runner.run(
      ProcessInvocation(
        executable: "git", arguments: arguments, workingDirectory: worktree.path,
        timeout: .seconds(60)))
    try #require(output.status.isSuccess, "git \(arguments): \(output.stderr.text)")
    return output.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func write(_ data: Data) throws -> String {
    let file = base.appending(path: "return-\(UUID().uuidString).json")
    try data.write(to: file)
    return file.path
  }

  func check(_ taskReturn: TaskReturn, fix: Bool = false) async throws -> BuildCheckReturnReport {
    await check(file: try write(try TaskReturnJSON.encode(taskReturn)), fix: fix)
  }

  func check(file: String, fix: Bool = false) async -> BuildCheckReturnReport {
    await BuildCheckReturnRun.run(file: file, plan: Self.plan, fix: fix, git: git)
  }

  /// Cuts the fix worktree `build merge` makes, on `<plan>/fix-<task>` from `main`, and commits
  /// the fixer's work there: `files`, or an empty commit when there are none.
  /// - Returns: the fix worktree and the fixer's commit.
  func cutFixWorktree(files: [String] = []) async throws -> (worktree: URL, commit: String) {
    let names = try TaskWorktree(
      commonDirectory: try await git.commonDirectory(), plan: Self.plan, task: "fix-\(Self.task)")
    let fix = URL(filePath: names.path, directoryHint: .isDirectory)
    let add = try await runner.run(
      ProcessInvocation(
        executable: "git",
        arguments: ["worktree", "add", "-q", "-b", names.branch, names.path, "main"],
        workingDirectory: main.path, timeout: .seconds(60)))
    try #require(add.status.isSuccess, "git worktree add: \(add.stderr.text)")
    for path in files {
      let file = fix.appending(path: path)
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("// \(path)\n".utf8).write(to: file)
    }
    let steps =
      (files.isEmpty ? [] : [["add", "--"] + files])
      + [["commit", "-q", "--allow-empty", "-m", "fix conflict"]]
    for arguments in steps {
      let output = try await runner.run(
        ProcessInvocation(
          executable: "git", arguments: arguments, workingDirectory: fix.path,
          timeout: .seconds(60)))
      try #require(output.status.isSuccess, "git \(arguments): \(output.stderr.text)")
    }
    return (
      fix,
      try #require(try await LiveGit(runner: runner, repositoryRoot: fix.path).revision("HEAD"))
    )
  }

  func remove() { TestTemporaryDirectory.remove(base) }
}

@Suite("build check-return")
struct BuildCheckReturnTests {
  @Test(
    "a fixer's commit on the fix branch with a GREEN merge-gate run in the fix worktree passes with --fix and is off-branch without it — catches a fixer's honest return refused, or checked against the task branch"
  )
  func fixReturnChecksTheFixBranch() async throws {
    let scenario = try await ReturnScenario()
    defer { scenario.remove() }
    let (fix, commit) = try await scenario.cutFixWorktree()
    let runID = try await scenario.recordGateRun(
      tier: .ready, verdict: .green, suffix: 2, in: fix, steps: nil)
    let fixReturn = scenario.returnValue(
      commits: [commit], gate: .init(tier: .ready, verdict: .green, runID: runID))

    let withFix = try await scenario.check(fixReturn, fix: true)
    let withoutFix = try await scenario.check(fixReturn)

    #expect(withFix.findings == [])
    #expect(withFix.verdict == .green)
    #expect(withoutFix.findings.map(\.rule).contains(.commitOffBranch))
    #expect(withoutFix.verdict.exitCode == 1)
  }

  @Test(
    "a fixer's return whose fix branch took in another unmerged task's branch, as a RED run over both cuts it, and edits that task's file passes --fix against both tasks' write sets — catches a fix of the file a red row points at read as an unexplained edit"
  )
  func fixOverTwoBranchesUsesBothWriteSets() async throws {
    let scenario = try await ReturnScenario()
    defer { scenario.remove() }
    let common = try await scenario.git.commonDirectory()
    let other = try TaskWorktree(
      commonDirectory: common, plan: ReturnScenario.plan, task: "queue-list")
    let names = try TaskWorktree(
      commonDirectory: common, plan: ReturnScenario.plan, task: ReturnScenario.task)
    let view = "Sources/QueueList/QueueListView.swift"
    func git(_ arguments: [String], in directory: String) async throws {
      let output = try await scenario.runner.run(
        ProcessInvocation(
          executable: "git", arguments: arguments, workingDirectory: directory,
          timeout: .seconds(60)))
      try #require(output.status.isSuccess, "git \(arguments): \(output.stderr.text)")
    }
    func write(_ path: String, in directory: String, _ text: String) throws {
      let file = URL(filePath: directory).appending(path: path)
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(text.utf8).write(to: file)
    }
    try await git(
      ["worktree", "add", "-q", "-b", other.branch, other.path, "main"], in: scenario.main.path)
    try write(view, in: other.path, "struct QueueListView {}\n")
    try await git(["add", "-A"], in: other.path)
    try await git(["commit", "-q", "-m", "list view"], in: other.path)
    let plan = try PlanStateLayout(commonDirectory: common).plan(ReturnScenario.plan)
    var ledger = try PlanStateStore(plan: plan).ledger()
    ledger = Ledger(
      schemaVersion: ledger.schemaVersion, resume: ledger.resume, maxParallel: ledger.maxParallel,
      tasks: ledger.tasks + [
        LedgerTask(
          id: "queue-list", deps: [], writeSet: ["Sources/QueueList/"], gate: .push, tests: [],
          covers: ["D2"], estLines: 20, status: .inProgress, worktree: other.path,
          model: .sonnet, branch: other.branch)
      ], waves: [[ReturnScenario.task, "queue-list"]])
    try LedgerJSON.encode(ledger).write(to: URL(filePath: plan.ledgerFile))
    let (fix, _) = try await scenario.cutFixWorktree()
    for branch in [names.branch, other.branch] {
      try await git(["merge", "-q", "--no-ff", "--no-edit", branch], in: fix.path)
    }
    try write(view, in: fix.path, "struct QueueListView { let tappable = true }\n")
    try await git(["commit", "-q", "-am", "fix: the list row takes taps"], in: fix.path)
    let commit = try #require(
      try await LiveGit(runner: scenario.runner, repositoryRoot: fix.path).revision("HEAD"))
    let runID = try await scenario.recordGateRun(
      tier: .ready, verdict: .green, suffix: 2, in: fix, steps: nil)

    let report = try await scenario.check(
      scenario.returnValue(
        commits: [commit], gate: .init(tier: .ready, verdict: .green, runID: runID),
        notes: "The row button gets a content shape.", review: nil),
      fix: true)

    #expect(report.findings == [], "\(report.findings)")
    #expect(report.verdict == .green)
  }

  @Test(
    "a fixer's edit to a merged task's file, its notes silent, is unexplained until the task's before-merge run is RED in a row that runs after that merged task too, and then passes --fix against that task's write set — catches a fixer blamed for a red screen another task owns, held outside the files that screen lives in"
  )
  func fixMayEditTheMergedOwnerOfARedRow() async throws {
    let scenario = try await ReturnScenario()
    defer { scenario.remove() }
    let common = try await scenario.git.commonDirectory()
    let view = "Sources/QueueList/QueueListView.swift"
    func git(_ arguments: [String], in directory: String) async throws {
      let output = try await scenario.runner.run(
        ProcessInvocation(
          executable: "git", arguments: arguments, workingDirectory: directory,
          timeout: .seconds(60)))
      try #require(output.status.isSuccess, "git \(arguments): \(output.stderr.text)")
    }
    func write(_ path: String, in directory: String, _ text: String) throws {
      let file = URL(filePath: directory).appending(path: path)
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(text.utf8).write(to: file)
    }
    try write(view, in: scenario.main.path, "struct QueueListView {}\n")
    try await git(["add", "-A"], in: scenario.main.path)
    try await git(["commit", "-q", "-m", "Merge: list view"], in: scenario.main.path)
    let plan = try PlanStateLayout(commonDirectory: common).plan(ReturnScenario.plan)
    var ledger = try PlanStateStore(plan: plan).ledger()
    ledger = Ledger(
      schemaVersion: ledger.schemaVersion, resume: ledger.resume, maxParallel: ledger.maxParallel,
      tasks: ledger.tasks + [
        LedgerTask(
          id: "queue-list", deps: [], writeSet: ["Sources/QueueList/"], gate: .push, tests: [],
          covers: ["D2"], estLines: 20, status: .done, worktree: scenario.main.path + "-list",
          model: .sonnet)
      ], waves: [[ReturnScenario.task, "queue-list"]])
    try LedgerJSON.encode(ledger).write(to: URL(filePath: plan.ledgerFile))
    let (fix, _) = try await scenario.cutFixWorktree()
    try write(view, in: fix.path, "struct QueueListView { let searchable = true }\n")
    try await git(["commit", "-q", "-am", "fix: the search field takes text"], in: fix.path)
    let commit = try #require(
      try await LiveGit(runner: scenario.runner, repositoryRoot: fix.path).revision("HEAD"))
    let runID = try await scenario.recordGateRun(
      tier: .ready, verdict: .green, suffix: 2, in: fix, steps: nil)
    let fixReturn = scenario.returnValue(
      commits: [commit], gate: .init(tier: .ready, verdict: .green, runID: runID),
      notes: "The search field takes text.", review: nil)

    let before = try await scenario.check(fixReturn, fix: true)
    let captured = try QAReportJSON.decode(
      Fixture.data("BrownfieldTrial/send-money-6-qa-fixer-before-merge.json"))
    let red = try #require(captured.rows.first { $0.result == .red })
    let names = try TaskWorktree(
      commonDirectory: common, plan: ReturnScenario.plan, task: ReturnScenario.task)
    let redRun = "20261005T094736Z-1149c44c"
    let report = QAReport(
      runID: redRun, plan: ReturnScenario.plan, after: ReturnScenario.task, atBase: false,
      commit: nil,
      rows: [
        QARow(
          row: 1, requirement: red.requirement, layer: red.layer, check: red.check,
          runsAfter: ["queue-list", ReturnScenario.task], result: .red, message: red.message)
      ],
      trialMerge: QATrialMerge(
        branch: names.branch, tip: scenario.taskCommit, base: scenario.taskCommit))
    let directory = try RunStore(worktreeRoot: scenario.main).runDirectory(for: redRun)
      .appending(path: QAReport.directory, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try QAReportJSON.encode(report).write(to: directory.appending(path: QAReport.fileName))
    let after = try await scenario.check(fixReturn, fix: true)

    #expect(before.findings.map(\.rule) == [.outsideWriteSetUnexplained], "\(before.findings)")
    #expect(after.findings == [], "\(after.findings)")
    #expect(after.verdict == .green)
  }

  @Test(
    "a fixer's ready-to-merge return with review null passes --fix, and a worker's with review null still fails — catches the fix path rejecting every fixer, or a worker skipping review"
  )
  func fixReturnNeedsNoReview() async throws {
    let scenario = try await ReturnScenario()
    defer { scenario.remove() }
    let (fix, commit) = try await scenario.cutFixWorktree()
    let fixRun = try await scenario.recordGateRun(
      tier: .ready, verdict: .green, suffix: 2, in: fix, steps: nil)
    let workerRun = try await scenario.recordGateRun(tier: .push, verdict: .green, suffix: 1)

    let fixer = try await scenario.check(
      scenario.returnValue(
        commits: [commit], gate: .init(tier: .ready, verdict: .green, runID: fixRun),
        review: nil),
      fix: true)
    let worker = try await scenario.check(
      scenario.returnValue(
        gate: .init(tier: .push, verdict: .green, runID: workerRun), review: nil))

    #expect(fixer.findings == [], "\(fixer.findings)")
    #expect(fixer.verdict.exitCode == 0)
    #expect(worker.findings.map(\.rule) == [.reviewMissing])
    #expect(worker.verdict.exitCode == 1)
  }

  @Test(
    "a fix return whose GREEN gate is below the preset's merge gate is a below-task-gate finding — catches a fixer passing the task gate when the merge gate decides"
  )
  func fixReturnMeetsTheMergeGate() async throws {
    let scenario = try await ReturnScenario(ledgerGate: .push, presetGate: .tier(.push))
    defer { scenario.remove() }
    let (fix, commit) = try await scenario.cutFixWorktree()
    let runID = try await scenario.recordGateRun(tier: .push, verdict: .green, suffix: 2, in: fix)

    let report = try await scenario.check(
      scenario.returnValue(
        commits: [commit], gate: .init(tier: .push, verdict: .green, runID: runID)),
      fix: true)

    #expect(report.findings.map(\.rule) == [.gateBelowTaskGate])
    #expect(report.verdict.exitCode == 1)
  }

  @Test(
    "a return whose commit is on the task branch and whose GREEN push run is in the worktree's run store passes with exit 0 — catches the check refusing an honest return"
  )
  func honestReturnPasses() async throws {
    let scenario = try await ReturnScenario()
    defer { scenario.remove() }
    let runID = try await scenario.recordGateRun(tier: .push, verdict: .green, suffix: 1)

    let report = try await scenario.check(
      scenario.returnValue(gate: .init(tier: .push, verdict: .green, runID: runID)))

    #expect(report.findings == [])
    #expect(report.verdict == .green)
    #expect(report.verdict.exitCode == 0)
  }

  @Test(
    "a file the task's commits touch outside its write set, and its notes never name, is a finding with exit 1 — catches a worker spreading past its write set in silence"
  )
  func unexplainedEditOutsideWriteSetFails() async throws {
    let scenario = try await ReturnScenario()
    defer { scenario.remove() }
    let commit = try await scenario.commitFiles(["Sources/Queue/Queue.swift", "App/AppView.swift"])
    let runID = try await scenario.recordGateRun(tier: .push, verdict: .green, suffix: 1)

    let report = try await scenario.check(
      scenario.returnValue(
        commits: [scenario.taskCommit, commit],
        gate: .init(tier: .push, verdict: .green, runID: runID)))

    #expect(report.findings.map(\.rule) == [.outsideWriteSet])
    #expect(report.findings.first?.message.contains("App/AppView.swift") == true)
    #expect(report.verdict.exitCode == 1)
  }

  @Test(
    "a worker's edit outside the write set fails even when the notes explain it — catches an explained edit slipping past the write set into main"
  )
  func explainedEditOutsideWriteSetFails() async throws {
    let scenario = try await ReturnScenario()
    defer { scenario.remove() }
    let commit = try await scenario.commitFiles(["App/AppView.swift"])
    let runID = try await scenario.recordGateRun(tier: .push, verdict: .green, suffix: 1)

    let report = try await scenario.check(
      scenario.returnValue(
        commits: [scenario.taskCommit, commit],
        gate: .init(tier: .push, verdict: .green, runID: runID),
        notes: "Edited App/AppView.swift, 4 lines, so the UI target keeps compiling."))

    #expect(report.findings.map(\.rule) == [.outsideWriteSet])
    #expect(report.verdict.exitCode == 1)
  }

  @Test(
    "a fixer's edit outside the task's write set that its notes name passes with a warning, and one they never name fails — catches a fix blocked for resolving the other task's file, or spreading in silence"
  )
  func fixEditOutsideWriteSetNeedsANote() async throws {
    let scenario = try await ReturnScenario()
    defer { scenario.remove() }
    let (fix, commit) = try await scenario.cutFixWorktree(files: ["App/AppView.swift"])
    let runID = try await scenario.recordGateRun(tier: .ready, verdict: .green, suffix: 2, in: fix)
    let gate = TaskReturn.Gate(tier: .ready, verdict: .green, runID: runID)

    let explained = try await scenario.check(
      scenario.returnValue(
        commits: [commit], gate: gate,
        notes: "Resolved App/AppView.swift, which both tasks edited."),
      fix: true)
    let unexplained = try await scenario.check(
      scenario.returnValue(commits: [commit], gate: gate), fix: true)

    #expect(explained.findings == [])
    #expect(explained.warnings.contains { $0.contains("App/AppView.swift") })
    #expect(unexplained.findings.map(\.rule) == [.outsideWriteSetUnexplained])
  }

  @Test(
    "a GREEN task gate below ready that ran no prove or mutate is a finding — catches a task merged without its red/green proof"
  )
  func greenGateWithoutProofFails() async throws {
    let scenario = try await ReturnScenario()
    defer { scenario.remove() }
    let runID = try await scenario.recordGateRun(
      tier: .push, verdict: .green, suffix: 1, steps: nil)

    let report = try await scenario.check(
      scenario.returnValue(gate: .init(tier: .push, verdict: .green, runID: runID)))

    #expect(report.findings.map(\.rule) == [.gateMissingProof, .gateMissingStep])
    #expect(report.verdict.exitCode == 1)
  }

  @Test(
    "an unproved GREEN worker gate that skipped app-build fails proof only under a per-task preset, and the missing step under both — catches a preset that silently skips proof or the task gate's steps"
  )
  func proofRequirementFollowsThePresetsTaskProof() async throws {
    let perTask = try await ReturnScenario(taskProof: .perTask)
    defer { perTask.remove() }
    let perTaskRun = try await perTask.recordGateRun(
      tier: .push, verdict: .green, suffix: 1, steps: nil)
    let perTaskReport = try await perTask.check(
      perTask.returnValue(gate: .init(tier: .push, verdict: .green, runID: perTaskRun)))

    let final = try await ReturnScenario(taskProof: .final)
    defer { final.remove() }
    let finalRun = try await final.recordGateRun(
      tier: .push, verdict: .green, suffix: 1, steps: nil)
    let finalReport = try await final.check(
      final.returnValue(gate: .init(tier: .push, verdict: .green, runID: finalRun)))

    #expect(perTaskReport.findings.map(\.rule) == [.gateMissingProof, .gateMissingStep])
    #expect(finalReport.findings.map(\.rule) == [.gateMissingStep])
  }

  @Test(
    "a worker's GREEN return citing a push run that never ran --app-build fails naming app-build, and a fixer's merge gate without it passes — catches a worker that skips the task gate's new steps"
  )
  func workerGateWithoutAppBuildFails() async throws {
    let scenario = try await ReturnScenario()
    defer { scenario.remove() }
    let workerRun = try await scenario.recordGateRun(
      tier: .push, verdict: .green, suffix: 1, steps: ["prove", "mutate"])
    let (fix, commit) = try await scenario.cutFixWorktree()
    let fixRun = try await scenario.recordGateRun(
      tier: .ready, verdict: .green, suffix: 2, in: fix, steps: nil)

    let worker = try await scenario.check(
      scenario.returnValue(gate: .init(tier: .push, verdict: .green, runID: workerRun)))
    let fixer = try await scenario.check(
      scenario.returnValue(
        commits: [commit], gate: .init(tier: .ready, verdict: .green, runID: fixRun),
        review: nil),
      fix: true)

    #expect(worker.findings.map(\.rule) == [.gateMissingStep])
    #expect(worker.findings.first?.message.contains("app-build") == true)
    #expect(worker.findings.first?.message.contains(workerRun) == true)
    #expect(worker.verdict.exitCode == 1)
    #expect(fixer.findings == [], "\(fixer.findings)")
    #expect(fixer.verdict == .green)
  }

  @Test(
    "a fast run recorded before steps were recorded fails a worker's GREEN return with one finding per missing step — catches an old run passing silently, or missing steps lumped into one"
  )
  func runWithoutRecordedStepsNamesEachMissingStep() async throws {
    let scenario = try await ReturnScenario(ledgerGate: .fast, taskProof: .final)
    defer { scenario.remove() }
    let runID = try await scenario.recordGateRun(
      tier: .fast, verdict: .green, suffix: 1, steps: nil)

    let report = try await scenario.check(
      scenario.returnValue(gate: .init(tier: .fast, verdict: .green, runID: runID)))

    #expect(report.findings.map(\.rule) == [.gateMissingStep, .gateMissingStep, .gateMissingStep])
    let named = report.findings.map { finding in
      ["impact", "coverage", "app-build"].filter { finding.message.contains("`\($0)`") }
    }
    #expect(named == [["impact"], ["coverage"], ["app-build"]])
    #expect(report.verdict.exitCode == 1)
  }

  @Test(
    "a worker run with every task gate step passes under either task_proof, counting the steps its tier already runs — catches a push run refused for the impact and coverage push runs anyway"
  )
  func runWithEveryStepPasses() async throws {
    let perTask = try await ReturnScenario(taskProof: .perTask)
    defer { perTask.remove() }
    let perTaskRun = try await perTask.recordGateRun(
      tier: .push, verdict: .green, suffix: 1, steps: ["prove", "mutate", "app-build"])
    let perTaskReport = try await perTask.check(
      perTask.returnValue(gate: .init(tier: .push, verdict: .green, runID: perTaskRun)))

    let final = try await ReturnScenario(taskProof: .final)
    defer { final.remove() }
    let finalRun = try await final.recordGateRun(
      tier: .push, verdict: .green, suffix: 1, steps: ["app-build"])
    let skipped = try await final.recordGateRun(tier: .push, verdict: .green, suffix: 2, steps: nil)
    let finalReport = try await final.check(
      final.returnValue(gate: .init(tier: .push, verdict: .green, runID: finalRun)))
    let skippedReport = try await final.check(
      final.returnValue(gate: .init(tier: .push, verdict: .green, runID: skipped)))

    #expect(perTaskReport.findings == [], "\(perTaskReport.findings)")
    #expect(perTaskReport.verdict == .green)
    #expect(finalReport.findings == [], "\(finalReport.findings)")
    #expect(finalReport.verdict == .green)
    #expect(skippedReport.findings.map(\.rule) == [.gateMissingStep])
  }

  @Test(
    "a surface commit on the task branch that the gate run proved at passes; one the gate never used as a proof base fails — catches a surface commit claimed but not proven against"
  )
  func surfaceCommitMustBeAProofBase() async throws {
    let scenario = try await ReturnScenario()
    defer { scenario.remove() }
    let surface = try await scenario.commitFiles(["Sources/Queue/Queue.swift"])
    let proven = try await scenario.recordGateRun(
      tier: .push, verdict: .green, suffix: 1, proofBases: [surface])
    let unproven = try await scenario.recordGateRun(tier: .push, verdict: .green, suffix: 2)

    let withProof = try await scenario.check(
      scenario.returnValue(
        commits: [scenario.taskCommit, surface],
        gate: .init(tier: .push, verdict: .green, runID: proven), surfaceCommit: surface))
    let withoutProof = try await scenario.check(
      scenario.returnValue(
        commits: [scenario.taskCommit, surface],
        gate: .init(tier: .push, verdict: .green, runID: unproven), surfaceCommit: surface))

    #expect(withProof.findings == [])
    #expect(withoutProof.findings.map(\.rule) == [.surfaceCommitNotProofBase])
  }

  @Test(
    "a surface commit that isn't on the task branch is a finding — catches a proof base borrowed from another branch"
  )
  func surfaceCommitOffBranchFails() async throws {
    let scenario = try await ReturnScenario()
    defer { scenario.remove() }
    let runID = try await scenario.recordGateRun(
      tier: .push, verdict: .green, suffix: 1, proofBases: ["0123456789abcdef"])

    let report = try await scenario.check(
      scenario.returnValue(
        gate: .init(tier: .push, verdict: .green, runID: runID),
        surfaceCommit: "0123456789abcdef"))

    #expect(report.findings.map(\.rule) == [.surfaceCommitOffBranch])
  }

  @Test(
    "commits inside the write set raise no write-set warning — catches the check flagging every task"
  )
  func editsInsideWriteSetAreQuiet() async throws {
    let scenario = try await ReturnScenario()
    defer { scenario.remove() }
    let commit = try await scenario.commitFiles(["Sources/Queue/Queue.swift"])
    let runID = try await scenario.recordGateRun(tier: .push, verdict: .green, suffix: 1)

    let report = try await scenario.check(
      scenario.returnValue(
        commits: [scenario.taskCommit, commit],
        gate: .init(tier: .push, verdict: .green, runID: runID)))

    #expect(report.findings == [])
    #expect(!report.warnings.contains { $0.contains("write set") })
  }

  @Test(
    "a commit that exists only on another branch is a commit-off-branch finding with exit 1 — catches a worker citing work that isn't on its task branch"
  )
  func commitOnAnotherBranchFails() async throws {
    let scenario = try await ReturnScenario()
    defer { scenario.remove() }
    let runID = try await scenario.recordGateRun(tier: .push, verdict: .green, suffix: 1)

    let report = try await scenario.check(
      scenario.returnValue(
        commits: [scenario.taskCommit, scenario.elsewhereCommit],
        gate: .init(tier: .push, verdict: .green, runID: runID)))

    #expect(report.findings.map(\.rule) == [.commitOffBranch])
    #expect(report.findings.first?.message.contains(scenario.elsewhereCommit) == true)
    #expect(report.verdict.exitCode == 1)
  }

  @Test(
    "a gate run id the worktree's run store doesn't hold is a gate-run-missing finding — catches a worker citing a run that never happened"
  )
  func unknownRunIDFails() async throws {
    let scenario = try await ReturnScenario()
    defer { scenario.remove() }
    _ = try await scenario.recordGateRun(tier: .push, verdict: .green, suffix: 1)
    let invented = RunID.make(startedAt: ReturnScenario.finishedAt, suffix: 0xdead)

    let report = try await scenario.check(
      scenario.returnValue(gate: .init(tier: .push, verdict: .green, runID: invented)))

    #expect(report.findings.map(\.rule) == [.gateRunMissing])
    #expect(report.verdict.exitCode == 1)
  }

  @Test(
    "a RED run claimed as GREEN is a verdict-mismatch and not-green finding — catches a worker overstating its gate"
  )
  func redRunClaimedGreenFails() async throws {
    let scenario = try await ReturnScenario()
    defer { scenario.remove() }
    let runID = try await scenario.recordGateRun(tier: .push, verdict: .red, suffix: 1)

    let report = try await scenario.check(
      scenario.returnValue(gate: .init(tier: .push, verdict: .green, runID: runID)))

    #expect(report.findings.map(\.rule) == [.gateVerdictMismatch, .gateNotGreen])
    #expect(report.verdict.exitCode == 1)
  }

  @Test(
    "a GREEN fast run for a push-gated task is a below-task-gate finding, from the ledger's gate or the preset's fixed tier — catches a worker passing a cheaper tier than its task demands"
  )
  func lowerTierThanTaskGateFails() async throws {
    let ledgerGated = try await ReturnScenario(ledgerGate: .push, presetGate: .ledger)
    defer { ledgerGated.remove() }
    let fastRun = try await ledgerGated.recordGateRun(tier: .fast, verdict: .green, suffix: 1)
    let report = try await ledgerGated.check(
      ledgerGated.returnValue(gate: .init(tier: .fast, verdict: .green, runID: fastRun)))
    #expect(report.findings.map(\.rule) == [.gateBelowTaskGate])
    #expect(report.verdict.exitCode == 1)

    let presetGated = try await ReturnScenario(ledgerGate: .fast, presetGate: .tier(.push))
    defer { presetGated.remove() }
    let presetRun = try await presetGated.recordGateRun(tier: .fast, verdict: .green, suffix: 1)
    let presetReport = try await presetGated.check(
      presetGated.returnValue(gate: .init(tier: .fast, verdict: .green, runID: presetRun)))
    #expect(presetReport.findings.map(\.rule) == [.gateBelowTaskGate])
  }

  @Test(
    "a design-conflict outcome with no task-status.json in the worktree is a design-conflict-unrecorded finding — catches a conflict the orchestrator can't check against the worker's own report"
  )
  func designConflictWithoutTaskStatusFails() async throws {
    let scenario = try await ReturnScenario()
    defer { scenario.remove() }
    let conflict = TaskStatusReport.Report(
      kind: "design-conflict", section: "decision", ids: ["req-queue-drains-on-reconnect"],
      claim: "the endpoint caps batches at 20", evidence: [])

    let report = try await scenario.check(
      scenario.returnValue(outcome: .designConflict, gate: nil, designConflict: conflict))
    #expect(report.findings.map(\.rule) == [.designConflictUnrecorded])
    #expect(report.verdict.exitCode == 1)

    let statusFile = scenario.worktree.appending(path: ".harness/task-status.json")
    try FileManager.default.createDirectory(
      at: statusFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try TaskStatusReportJSON.encode(
      TaskStatusReport(task: ReturnScenario.task, state: "blocked", report: conflict)
    ).write(to: statusFile)
    let recorded = try await scenario.check(
      scenario.returnValue(outcome: .designConflict, gate: nil, designConflict: conflict))
    #expect(recorded.findings == [])
  }

  @Test(
    "an unknown outcome or a missing key fails decoding and exits 2 naming it — catches a return the check would otherwise read as something it isn't"
  )
  func unknownOutcomeFailsDecoding() async throws {
    let scenario = try await ReturnScenario()
    defer { scenario.remove() }
    let runID = try await scenario.recordGateRun(tier: .push, verdict: .green, suffix: 1)
    let valid = try TaskReturnJSON.encode(
      scenario.returnValue(gate: .init(tier: .push, verdict: .green, runID: runID)))
    var object = try #require(try JSONSerialization.jsonObject(with: valid) as? [String: Any])

    object["outcome"] = "merged"
    let unknownOutcome = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: DecodingError.self) { try TaskReturnJSON.decode(unknownOutcome) }
    let report = await scenario.check(file: try scenario.write(unknownOutcome))
    #expect(report.verdict.exitCode == 2)
    #expect(report.message.contains("merged"), "\(report.message)")

    object["outcome"] = "ready-to-merge"
    object.removeValue(forKey: "designConflict")
    let missingKey = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: TaskReturnDecodingError.missingKey("designConflict")) {
      try TaskReturnJSON.decode(missingKey)
    }
    let missingReport = await scenario.check(file: try scenario.write(missingKey))
    #expect(missingReport.verdict.exitCode == 2)
    #expect(missingReport.message.contains("designConflict"), "\(missingReport.message)")
  }

  @Test(
    "a return whose review carries a captured review-contract finding decodes and round-trips, and one missing a contract key fails decoding — catches review findings the orchestrator can't read back as the contract"
  )
  func reviewFindingsUseTheReviewContract() throws {
    let captured = try FocusReviewJSON.decode(Fixture.data("Review/d7-api-errors.json"))
    let finding = try #require(captured.findings.first)
    let original = TaskReturn(
      task: "t", outcome: .reviewBlocked, commits: ["abc1"],
      gate: .init(tier: .push, verdict: .green, runID: "r1"),
      review: .init(mode: .full, findings: [finding]), testsAdded: [], notes: "",
      designConflict: nil)

    let decoded = try TaskReturnJSON.decode(try TaskReturnJSON.encode(original))
    #expect(decoded == original)
    #expect(decoded.review?.findings.first?.rule == "D7")

    var object = try #require(
      try JSONSerialization.jsonObject(with: try TaskReturnJSON.encode(original))
        as? [String: Any])
    var review = try #require(object["review"] as? [String: Any])
    var findings = try #require(review["findings"] as? [[String: Any]])
    findings[0].removeValue(forKey: "severity")
    review["findings"] = findings
    object["review"] = review
    let missingSeverity = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: DecodingError.self) { try TaskReturnJSON.decode(missingSeverity) }
  }
}

@Suite("build check-return records its verdict")
struct BuildCheckReturnRecordTests {
  /// The `build.return-checked` events in the scenario's main checkout store.
  private static func recorded(_ scenario: ReturnScenario) throws -> [BuildReturnCheckedEvent] {
    let data = try HarnessEventFiles(root: scenario.main).read(.build, runID: nil) ?? Data()
    return try HarnessEventJSON.decode(data).events.compactMap { event in
      guard case .buildReturnChecked(let checked) = event.payload else { return nil }
      return checked
    }
  }

  private static func checked(_ scenario: ReturnScenario, _ taskReturn: TaskReturn) async throws
    -> BuildCheckReturnRun.Checked
  {
    // A checkout with a config keeps events, as a harness repository does.
    try Data(
      """
      schema = 1
      xcode = "26.2"
      app_scheme = "App"
      packages = ["Packages/*"]

      [simulator]
      device = "iPhone 17"
      os = "26.2"

      """.utf8
    ).write(to: scenario.main.appending(path: ".swiftgate.toml"))
    return await BuildCheckReturnRun.check(
      file: try scenario.write(try TaskReturnJSON.encode(taskReturn)), plan: ReturnScenario.plan,
      git: scenario.git, directory: scenario.main.path)
  }

  @Test(
    "a return check-return rejects for a quoted surface commit is recorded as build.return-checked with its task, build run, verdict and rule — catches a rejection that leaves no record for the run view"
  )
  func rejectionIsRecorded() async throws {
    let scenario = try await ReturnScenario()
    defer { scenario.remove() }
    let runID = try await scenario.recordGateRun(tier: .push, verdict: .green, suffix: 2)
    let quoted = "\"\(scenario.taskCommit.prefix(8))\""
    let result = try await Self.checked(
      scenario,
      scenario.returnValue(
        gate: .init(tier: .push, verdict: .green, runID: runID), surfaceCommit: quoted))

    #expect(result.report.verdict == .red)
    #expect(result.notRecorded == [])
    let events = try Self.recorded(scenario)
    #expect(events.count == 1)
    let event = try #require(events.first)
    #expect(event.task == ReturnScenario.task)
    #expect(
      event.buildRun == RunID.make(startedAt: ReturnScenario.finishedAt, suffix: 1))
    #expect(event.verdict == .red)
    #expect(event.fix == false)
    #expect(event.rules == result.report.findings.map(\.rule))
    #expect(event.rules.contains(.surfaceCommitOffBranch))
    #expect(event.findings.map(\.rule) == event.rules)
    #expect(event.findings.first?.message.contains(quoted) == true)
  }

  @Test(
    "a BLOCKED check is recorded with its reason on 1 line and no machine path — catches a blocked return that leaves no record, or a record carrying the clone's absolute path"
  )
  func blockedCheckIsRecordedScrubbed() async throws {
    let scenario = try await ReturnScenario()
    defer { scenario.remove() }
    let runID = try await scenario.recordGateRun(tier: .push, verdict: .green, suffix: 2)
    try FileManager.default.removeItem(at: scenario.worktree)
    let result = try await Self.checked(
      scenario, scenario.returnValue(gate: .init(tier: .push, verdict: .green, runID: runID)))

    #expect(result.report.verdict == .blocked)
    #expect(result.report.message.contains(scenario.worktree.lastPathComponent))
    let event = try #require(try Self.recorded(scenario).first)
    #expect(event.verdict == .blocked)
    #expect(event.rules == [])
    #expect(event.message.contains("has no worktree"))
    #expect(!event.message.contains(scenario.base.lastPathComponent), "\(event.message)")
    #expect(!event.message.contains("/var/"), "\(event.message)")
  }

  /// The `return-check` events in the plan's newest build run.
  private static func returnChecks(_ scenario: ReturnScenario) async throws
    -> [BuildEvent.ReturnCheck]
  {
    let run = try #require(
      try await BuildRunStore.latest(plan: ReturnScenario.plan, git: scenario.git))
    return try run.events().events.compactMap { event in
      guard case .returnCheck(let check) = event else { return nil }
      return check
    }
  }

  @Test(
    "with telemetry off, a GREEN check is recorded in the build run as a return-check naming the return's full last commit, and a RED one with its rules, both under the id the report's telemetry would carry — catches a verdict build merge can't read"
  )
  func verdictIsRecordedInTheBuildRun() async throws {
    let scenario = try await ReturnScenario()
    defer { scenario.remove() }
    let runID = try await scenario.recordGateRun(tier: .push, verdict: .green, suffix: 2)
    let short = String(scenario.taskCommit.prefix(10))
    let gate = TaskReturn.Gate(tier: .push, verdict: .green, runID: runID)

    let green = await BuildCheckReturnRun.check(
      file: try scenario.write(
        try TaskReturnJSON.encode(scenario.returnValue(commits: [short], gate: gate))),
      plan: ReturnScenario.plan, git: scenario.git, directory: scenario.main.path)
    let red = await BuildCheckReturnRun.check(
      file: try scenario.write(
        try TaskReturnJSON.encode(scenario.returnValue(commits: [short], gate: gate, review: nil))),
      plan: ReturnScenario.plan, git: scenario.git, directory: scenario.main.path)

    #expect(green.report.verdict == .green, "\(green.report.findings)")
    #expect(green.notRecorded == [] && red.notRecorded == [])
    let checks = try await Self.returnChecks(scenario)
    #expect(checks.map(\.verdict) == [.green, .red])
    #expect(checks.map(\.commit) == [scenario.taskCommit, scenario.taskCommit])
    #expect(checks.map(\.task) == [ReturnScenario.task, ReturnScenario.task])
    #expect(checks.last?.rules == [.reviewMissing])
    #expect(Set(checks.map(\.checkID)).count == 2)
  }

  @Test(
    "the trial's hand-written fixer return, a BLOCKED gate with a null run id, reads as a fix no gate checked and passes --fix recorded under its task, while the same return claiming a GREEN gate with no run id is BLOCKED naming that key and the null gate to write, recorded too — catches a refusal saying the check names no task and plan when both were given"
  )
  func unrunGateReadsAsAnUnconfirmedFix() async throws {
    let scenario = try await ReturnScenario()
    defer { scenario.remove() }
    let (_, commit) = try await scenario.cutFixWorktree()
    var object = try #require(
      try JSONSerialization.jsonObject(
        with: Fixture.data("BuildReturn/send-money-5/fix-send-flow-orchestrator.json"))
        as? [String: Any])
    object["task"] = ReturnScenario.task
    object["commits"] = [commit]
    let unrun = try scenario.write(try JSONSerialization.data(withJSONObject: object))
    var gate = try #require(object["gate"] as? [String: Any])
    gate["verdict"] = "GREEN"
    object["gate"] = gate
    let claimed = try scenario.write(try JSONSerialization.data(withJSONObject: object))

    let unconfirmed = await BuildCheckReturnRun.check(
      file: unrun, plan: ReturnScenario.plan, fix: true, git: scenario.git,
      directory: scenario.main.path)
    let lying = await BuildCheckReturnRun.check(
      file: claimed, plan: ReturnScenario.plan, fix: true, git: scenario.git,
      directory: scenario.main.path)

    #expect(unconfirmed.report.verdict == .green, "\(unconfirmed.report.findings)")
    #expect(unconfirmed.report.outcome == .gateRed)
    #expect(unconfirmed.notRecorded == [], "\(unconfirmed.notRecorded)")
    #expect(lying.report.verdict == .blocked)
    #expect(lying.report.task == ReturnScenario.task)
    #expect(lying.report.message.contains("`gate.runId`"), "\(lying.report.message)")
    #expect(lying.report.message.contains("\"gate\": null"), "\(lying.report.message)")
    #expect(lying.notRecorded == [], "\(lying.notRecorded)")
    let checks = try await Self.returnChecks(scenario)
    #expect(checks.map(\.verdict) == [.green, .blocked])
    #expect(checks.allSatisfy { $0.fix && $0.task == ReturnScenario.task })
  }

  @Test(
    "a GREEN return citing a gate run recorded at the commit before its last, or on a dirty tree at its last, fails build-return.stale-gate with exit 1 — catches a stale-head or dirty-tree gate accepted"
  )
  func staleGateRunFails() async throws {
    let scenario = try await ReturnScenario()
    defer { scenario.remove() }
    let early = try await scenario.recordGateRun(tier: .push, verdict: .green, suffix: 2)
    let last = try await scenario.commitFiles(["Sources/Queue/Queue.swift"])
    let dirty = try await scenario.recordGateRun(
      tier: .push, verdict: .green, suffix: 3, dirty: true)
    let clean = try await scenario.recordGateRun(tier: .push, verdict: .green, suffix: 4)
    func check(_ runID: String) async throws -> BuildCheckReturnReport {
      try await scenario.check(
        scenario.returnValue(
          commits: [scenario.taskCommit, last],
          gate: .init(tier: .push, verdict: .green, runID: runID)))
    }

    let staleHead = try await check(early)
    let dirtyTree = try await check(dirty)
    let fresh = try await check(clean)

    #expect(staleHead.findings.map(\.rule) == [.staleGate], "\(staleHead.findings)")
    #expect(staleHead.findings.first?.message.contains(scenario.taskCommit) == true)
    #expect(staleHead.findings.first?.message.contains(last) == true)
    #expect(staleHead.verdict.exitCode == 1)
    #expect(dirtyTree.findings.map(\.rule) == [.staleGate], "\(dirtyTree.findings)")
    #expect(dirtyTree.findings.first?.message.contains("uncommitted") == true)
    #expect(fresh.findings == [])
    #expect(fresh.commit == last)
  }
}

import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateRules

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
  /// The full sha of the return's last commit, the branch tip `build merge` requires; `nil` when
  /// the check couldn't resolve one.
  var commit: String? = nil
}

/// The testable core of `build check-return` (spec §5.3). Reads the return, the plan's ledger and
/// newest build run, git, and the task worktree's run store and `task-status.json`, and re-runs
/// no gate. Under a plan surface it builds the task's new and changed host tests at the proof
/// bases in scratch trees it removes. The judgement itself is ``TaskReturnCheck``.
enum BuildCheckReturnRun {
  static let command = "build check-return"

  private struct Blocked: Error {
    let message: String
    init(_ message: String) { self.message = message }
  }

  /// - Parameter fix: check a fixer's return: its commits are on `<plan>/fix-<task>`, its gate
  ///   run is in the fix worktree, the tier to meet is the run preset's merge gate, and its
  ///   `review` may be `null`.
  static func run(
    file: String, plan: String?, fix: Bool = false, git: any Git,
    profile: RepositoryProfile = .owned
  ) async -> BuildCheckReturnReport {
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
        taskReturn, plan: plan, fix: fix, git: git, profile: profile, warnings: &warnings)
      let findings = TaskReturnCheck.findings(taskReturn, evidence: evidence)
      return BuildCheckReturnReport(
        command: command, plan: plan, task: taskReturn.task,
        verdict: findings.isEmpty ? .green : .red, findings: findings, warnings: warnings,
        message: findings.isEmpty
          ? "task `\(taskReturn.task)`: the return matches git and the run store"
          : "task `\(taskReturn.task)`: \(findings.count) claim(s) the evidence doesn't support",
        commit: evidence.lastCommit)
    } catch {
      return blocked(taskReturn.task, error.message)
    }
  }

  /// What ``check(file:plan:fix:git:profile:directory:)`` found and recorded.
  struct Checked: Equatable {
    let report: BuildCheckReturnReport
    /// Why the verdict went unrecorded, for stderr; empty when it was recorded or telemetry is
    /// off.
    let notRecorded: [String]
  }

  /// ``run(file:plan:fix:git:profile:)``, then its verdict recorded as `build.return-checked` in
  /// the main checkout's store, the one `directory` belongs to.
  static func check(
    file: String, plan: String?, fix: Bool = false, git: any Git,
    profile: RepositoryProfile = .owned,
    directory: String = FileManager.default.currentDirectoryPath
  ) async -> Checked {
    let report = await run(file: file, plan: plan, fix: fix, git: git, profile: profile)
    return Checked(
      report: report,
      notRecorded: await record(
        report, fix: fix, git: git, profile: profile, directory: directory))
  }

  /// Appends `report` to the plan's newest build run as a `return-check` event, which `build
  /// merge` reads, then writes it as `build.return-checked` under the same id when telemetry is
  /// on. Returns why either went unwritten, except telemetry being off: a verdict on no task or no
  /// build run has nothing to name, and a failed write never changes the verdict.
  private static func record(
    _ report: BuildCheckReturnReport, fix: Bool, git: any Git, profile: RepositoryProfile,
    directory: String
  ) async -> [String] {
    let notRecorded = "the verdict wasn't recorded"
    guard let task = report.task, let plan = report.plan else {
      return ["\(notRecorded): the check names no task and plan"]
    }
    guard RunID.isValid(task) else { return ["\(notRecorded): task `\(task)` isn't an id"] }
    let store: BuildRunStore
    do {
      guard let latest = try await BuildRunStore.latest(plan: plan, git: git) else {
        return ["\(notRecorded): plan `\(plan)` has no build run"]
      }
      store = latest
    } catch {
      return ["\(notRecorded): listing plan `\(plan)`'s build runs: \(error)"]
    }
    let buildRun = store.runID
    let eventID = UUID().uuidString  // swiftgate:allow det.uuid-init — an id need only be unique
    let now = Date()  // swiftgate:allow det.date-init — stamps the check
    var rules: [TaskReturnFinding.Rule] = []
    for finding in report.findings where !rules.contains(finding.rule) {
      rules.append(finding.rule)
    }
    do throws(BuildRunStoreError) {
      try await store.append(
        .returnCheck(
          .init(
            task: task, fix: fix, verdict: report.verdict, commit: report.commit,
            checkID: eventID, rules: rules, at: now)))
    } catch {
      return [
        "\(notRecorded) in build run \(buildRun), so `build merge` will refuse this return: "
          + "\(error)"
      ]
    }
    let root: URL
    switch await BuildHaltRun.store(command: command, directory: directory) {
    case .refused(let refused): return [refused.stderr.trimmingCharacters(in: .newlines)]
    case .found(_, false): return []
    case .found(let found, true): root = found
    }
    var roots = [root.path, root.resolvingSymlinksInPath().path, directory]
    if let common = try? await git.commonDirectory(),
      let worktree = try? TaskWorktree(
        commonDirectory: common, plan: plan, task: fix ? "fix-\(task)" : task, profile: profile)
    {
      roots.append(worktree.path)
      roots.append(URL(filePath: worktree.path).resolvingSymlinksInPath().path)
    }
    roots.append(URL(filePath: directory).resolvingSymlinksInPath().path)
    let event = HarnessEvent(
      eventID: eventID, time: now,
      source: HarnessEventSource(route: nil),
      payload: .buildReturnChecked(
        .scrubbed(
          buildRun: buildRun, task: task, fix: fix, verdict: report.verdict,
          findings: report.findings, message: report.message, roots: roots)))
    do throws(HarnessEventWriteError) {
      try HarnessEventFiles(root: root).append(event)
    } catch {
      return ["\(notRecorded): \(error)"]
    }
    return []
  }

  private static func gather(
    _ taskReturn: TaskReturn, plan slug: String, fix: Bool, git: any Git,
    profile: RepositoryProfile, warnings: inout [String]
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
      of: task, plan: store.plan, slug: slug, fix: fix, profile: profile, git: git)
    let names: TaskWorktree
    do {
      names = try TaskWorktree(
        commonDirectory: try await git.commonDirectory(), plan: slug,
        task: fix ? "fix-\(task.id)" : task.id, profile: profile)
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
    var manifests: PlanSurfaceManifests?
    var testBuild: ProofBaseTestBuild?
    var lastCommit: String?
    var addedTests: [TaskReturnEvidence.AddedTest] = []
    let planSurface = try planSurfaceCommit(store, warnings: &warnings)
    if let branchTip {
      for commit in taskReturn.commits {
        commits[commit] = try await state(of: commit, onBranchAt: branchTip, git: git)
      }
      if let last = taskReturn.commits.last, commits[last] == .onBranch {
        do {
          lastCommit = try await git.revision(last)
        } catch {
          throw Blocked("reading commit \(last): \(error)")
        }
      }
      if let surfaceCommit = taskReturn.surfaceCommit {
        surface = try await state(of: surfaceCommit, onBranchAt: branchTip, git: git)
      }
      let changed = try await branchChanges(tip: branchTip, git: git)
      if let planSurface {
        manifests = try await surfaceManifests(
          changed, surface: planSurface, tip: branchTip, git: git)
        if changed.contains(where: { $0.hasSuffix(".swift") }) {
          testBuild = try await testsAtProofBases(
            plan: slug, planSurface: planSurface,
            stub: surface == .onBranch ? taskReturn.surfaceCommit : nil, tip: branchTip,
            worktree: worktree, git: git, warnings: &warnings)
        }
      }
      if profile == .brownfield {
        addedTests = try await brownfieldTests(
          changed, tip: branchTip, worktree: worktree, git: git, warnings: &warnings)
      }
      outside = WriteSet.outsideChanges(changed, writeSet: task.writeSet)
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
      surfaceCommit: surface, reviewRequired: !fix, taskGateStepsRequired: !fix,
      planSurface: manifests, testBuild: testBuild, lastCommit: lastCommit,
      addedTests: addedTests)
  }

  /// The test files the task branch adds or changes and still holds, in the areas that own them,
  /// for the areas whose `slice` runs changed tests alone. A test in any other area is a warning:
  /// a slice over the budget only builds it, so it first runs at `merge`.
  private static func brownfieldTests(
    _ changed: [String], tip: String, worktree: URL, git: any Git, warnings: inout [String]
  ) async throws(Blocked) -> [TaskReturnEvidence.AddedTest] {
    guard !changed.isEmpty else { return [] }
    let unmatched = "so the branch's tests weren't matched to the areas its gate tested"
    let config: BrownfieldConfig
    do {
      let common = URL(filePath: try await git.commonDirectory(), directoryHint: .isDirectory)
      guard
        case .brownfield(let loaded)? = try ConfigLoader().loadProfile(
          repositoryRoot: worktree, commonDir: common)
      else {
        warnings.append("the clone has no brownfield config, \(unmatched)")
        return []
      }
      config = loaded
    } catch {
      warnings.append("the clone's brownfield config can't be read (\(error)), \(unmatched)")
      return []
    }
    let tests = changed.filter { path in
      AreaGating.owner(of: path, in: config.areas).map { ChangedTestIDs.isTestFile(path, of: $0) }
        ?? false
    }
    guard !tests.isEmpty else { return [] }
    let held: Set<String>
    do {
      held = Set(try await git.contents(of: tests, at: tip).keys)
    } catch {
      throw Blocked("reading the task branch's test files at \(tip): \(error)")
    }
    var added: [TaskReturnEvidence.AddedTest] = []
    var buildOnly: [String] = []
    for path in tests where held.contains(path) {
      guard let area = AreaGating.owner(of: path, in: config.areas) else { continue }
      if area.selectsChangedTests {
        added.append(TaskReturnEvidence.AddedTest(path: path, area: area.name))
      } else {
        buildOnly.append(path)
      }
    }
    if !buildOnly.isEmpty {
      warnings.append(
        "\(buildOnly.joined(separator: ", ")) sit in areas whose test_files can't run changed "
          + "tests alone, so a slice over the budget only builds them and they first run at merge")
    }
    return added
  }

  /// Builds the host tests the task branch adds or changes, in scratch trees of its tip, with the
  /// production source it changed since the plan surface reverted to each proof base in turn:
  /// the plan surface, each merged task's stub the branch holds, then the return's own stub.
  /// `nil` when the branch changes no host test or no production source.
  private static func testsAtProofBases(
    plan slug: String, planSurface: String, stub: String?, tip: String, worktree: URL,
    git: any Git, warnings: inout [String]
  ) async throws(Blocked) -> ProofBaseTestBuild? {
    let worktreeGit = LiveGit(runner: LiveProcessRunner(), repositoryRoot: worktree.path)
    let head: String?
    let worktreeHead: String?
    do {
      head = try await git.revision("HEAD")
      worktreeHead = try await worktreeGit.revision("HEAD")
    } catch {
      throw Blocked("reading HEAD: \(error)")
    }
    guard let head else { throw Blocked("this checkout has no HEAD to measure the task from") }
    guard worktreeHead == tip else {
      throw Blocked(
        "the task worktree \(worktree.path) is at \(worktreeHead ?? "no commit"), not its branch "
          + "tip \(tip), so its tests can't be built as the branch holds them")
    }
    let swiftPM = ScopeResolution.liveSwiftPM(root: worktree)
    let graph: ModuleGraph
    switch await ConfiguredRepository.load(root: worktree, swiftPM: swiftPM, command: command) {
    case .failed(let outcome):
      warnings.append(
        "the task worktree's module graph can't be loaded (\(outcome)), so its tests weren't "
          + "built at the proof bases")
      return nil
    case .loaded(let loaded): graph = loaded.graph
    }
    let environment = ChangedTestChecks.Environment.live(
      root: worktree, git: worktreeGit, swiftPM: swiftPM)
    let selection: ChangedTestChecks.Selection
    switch await ChangedTestChecks.select(environment, graph: graph, base: head) {
    case .failure(let reason): throw Blocked("selecting the task's tests: \(reason.text)")
    case .success(let found): selection = found
    }
    guard !selection.packages.isEmpty else { return nil }
    let proofBases = try await proofBases(
      plan: slug, planSurface: planSurface, stub: stub, tip: tip, git: git)
    let prefix: String
    let reverted: [String]
    do throws(GitError) {
      prefix = try await worktreeGit.workingDirectoryPrefix()
      reverted =
        ChangedTestChecks.partition(
          try await worktreeGit.changedFiles(from: planSurface, to: tip), prefix: prefix,
          graph: graph
        ).reverted
    } catch {
      throw Blocked("listing the task branch's changes since the plan surface: \(error)")
    }
    guard !reverted.isEmpty else { return nil }
    let output = FileManager.default.temporaryDirectory.appending(
      path: "swiftgate-check-return-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { TemporaryDirectories.remove(output) }
    let builds:
      [(package: ChangedTestChecks.PackageTests, base: String, outcome: ProofBaseTestBuild.Outcome)]
    do throws(ScratchWorktreeError) {
      builds = try await ChangedTestChecks.buildAtProofBases(
        environment, selection: selection, revision: tip, reverted: reverted,
        proofBases: proofBases, prefix: prefix, output: output)
    } catch {
      throw Blocked("building the task's tests at the proof bases: scratch worktree: \(error)")
    }
    var uncompiled: [ProofBaseTestBuild.UncompiledFile] = []
    for build in builds {
      switch build.outcome {
      case .compiled: break
      case .testsDontCompile(let files): uncompiled += files
      case .noEvidence(let reason):
        warnings.append(
          "the tests of \(build.package.packagePath) say nothing at proof base \(build.base) "
            + "(\(reason)); the final gate's prove judges them")
      }
    }
    return ProofBaseTestBuild(proofBases: proofBases, uncompiled: uncompiled)
  }

  /// `build proof-bases`' list that the task branch holds, then the return's stub.
  private static func proofBases(
    plan slug: String, planSurface: String, stub: String?, tip: String, git: any Git
  ) async throws(Blocked) -> [String] {
    let listed = await BuildProofBasesRun.run(slug: slug, git: git)
    guard let report = listed.report, listed.verdict == .green else {
      throw Blocked("listing the plan's proof bases: \(listed.message)")
    }
    var bases: [String] = []
    do throws(GitError) {
      for base in [planSurface] + report.proofBases + (stub.map { [$0] } ?? [])
      where !bases.contains(base) {
        if try await git.isAncestor(base, of: tip) { bases.append(base) }
      }
    } catch {
      throw Blocked("reading the proof bases' ancestry: \(error)")
    }
    guard bases.first == planSurface else {
      throw Blocked(
        "the plan surface \(planSurface) isn't an ancestor of the task branch, so its tests "
          + "can't be built there")
    }
    return bases
  }

  /// `plan.json`'s `surfaceCommit`. A plan claimed before plan state had a `plan.json` has no
  /// surface to check against, which the warnings name.
  private static func planSurfaceCommit(_ store: PlanStateStore, warnings: inout [String])
    throws(Blocked) -> String?
  {
    do throws(PlanStateStoreError) {
      return try store.planFile().surfaceCommit
    } catch .missing(let path) {
      warnings.append("\(path) is missing, so no manifest was checked against a plan surface")
      return nil
    } catch {
      throw Blocked("reading the plan's surface commit: \(error)")
    }
  }

  /// Every `Package.swift` among `changed`, read at the plan surface and at the branch tip.
  private static func surfaceManifests(
    _ changed: [String], surface: String, tip: String, git: any Git
  ) async throws(Blocked) -> PlanSurfaceManifests {
    let paths = changed.filter(ManifestDeclarationsReader.isManifest)
    guard !paths.isEmpty else { return PlanSurfaceManifests(surface: surface, manifests: []) }
    let before: [String: String]
    let after: [String: String]
    do {
      before = try await git.contents(of: paths, at: surface)
      after = try await git.contents(of: paths, at: tip)
    } catch {
      throw Blocked("reading the task branch's manifests at the plan surface \(surface): \(error)")
    }
    return PlanSurfaceManifests(
      surface: surface,
      manifests: paths.map { path in
        SliceManifest(
          path: path, atSurface: before[path].map(ManifestDeclarationsReader.read),
          atHead: after[path].map(ManifestDeclarationsReader.read))
      })
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

  /// The preset's fixed tier, or the ledger's own when the preset defers to it. An owned fix is
  /// merged straight after, so it meets the preset's merge gate instead. A brownfield fix meets
  /// the task gate: its branch tip lacks whatever merged after it was cut, so a merge tier there
  /// gates a tree that never lands, and the plan branch's merge gate runs on the merged tree.
  /// Also the run preset's `taskProof`, which says whether the task gate had to prove and mutate.
  private static func taskGate(
    of task: LedgerTask, plan: PlanStateLayout.Plan, slug: String, fix: Bool,
    profile: RepositoryProfile, git: any Git
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
    if fix, profile == .owned { return (record.preset.mergeGate, proof) }
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
    return TaskReturnEvidence.GateRun(record: record)
  }

  private static func taskStatus(in worktree: URL) throws(Blocked) -> TaskStatusReport? {
    let file = StateRootResolver.resolve(worktree: worktree).url(RunLayout.taskStatusFile)
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
      + "gate or above for ready-to-merge and review-blocked, and for a worker having run the "
      + "task gate's impact, coverage and app-build steps), and that designConflict matches "
      + "the worktree's .harness/task-status.json. For a plan with a surface commit it also "
      + "checks the task's manifests against that surface, and builds the host tests the branch "
      + "adds or changes with its production source reverted to each proof base (the plan "
      + "surface, merged tasks' stubs, the return's surfaceCommit) in scratch worktrees it "
      + "removes: a test file that compiles at none is build-return.test-needs-stub. Re-runs no "
      + "gate. A ready-to-merge or review-blocked return's gate run must have started at the "
      + "return's last commit on a clean tree (build-return.stale-gate). In a brownfield clone, "
      + "a test file the branch adds or changes in an area whose test_files narrows a run must "
      + "have run in that gate (build-return.tests-not-run). Records the verdict in "
      + "the plan's newest build run as a return-check event naming the return's last commit, "
      + "which build merge requires GREEN at the branch tip it merges, and as build.return-checked "
      + "in the main checkout's store: the task, the verdict, the rule ids and each finding's "
      + "message on 1 line, cut and with machine paths taken out; a failed write prints 1 line "
      + "and changes nothing. Exits 0 when every claim holds, 1 for any finding, and 2 when the return or plan "
      + "state can't be read.")

  @Argument(help: "Path to the task's return JSON file.")
  var file: String

  @Option(help: "The slug of the plan the task belongs to.")
  var plan: String?

  @Option(
    help: ArgumentHelp(
      "The orchestrator's session id. Accepted so every build verb takes it; this check claims "
        + "nothing, so it isn't required."))
  var session: String?

  @Flag(
    help: ArgumentHelp(
      "Check a fixer's return: commits on <plan>/fix-<task>, the gate run in the fix worktree, "
        + "and the run preset's merge gate as the tier to meet; its review may be null."))
  var fix = false

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let git = LiveGit(runner: LiveProcessRunner(), repositoryRoot: root.path)
    let checked = await BuildCheckReturnRun.check(
      file: file, plan: plan, fix: fix, git: git, profile: BuildPresetCatalog.profile(root: root),
      directory: root.path)
    for note in checked.notRecorded {
      FileHandle.standardError.write(Data("swiftgate build check-return: \(note)\n".utf8))
    }
    let report = checked.report
    Console.write(BuildCheckReturnRun.render(report, format: output.format))
    if report.verdict != .green { throw ExitCode(report.verdict.exitCode) }
  }
}

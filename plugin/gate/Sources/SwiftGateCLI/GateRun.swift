import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import Synchronization

/// What a multi-tier command produced, before it becomes a ``RunReport``.
struct GateRunParts: Sendable {
  var tiers: [TierResult] = []
  var findings: [Finding] = []
  var allowances: [AllowanceCount] = []
  /// Failures a brownfield gate found at the merge base too, so they didn't gate; `nil` for a run
  /// with no baseline.
  var baselineCount: Int?
}

/// Shared driver for commands that run tests: allocates the run (id and artifact directory),
/// times it, records the report and its history line, prints, and exits with the verdict.
enum GateRun {
  struct Context: Sendable {
    let runID: String
    /// Where the run's logs and reports go.
    let directory: URL
    /// Each step the run times hands its timing here, for the run's `gate.step` events.
    var steps = GateStepCollector()
    /// Each test tier hands its parsed cases here, for the run's `test.result` events. They never
    /// enter the report.
    var tests = TestResultCollector()
    /// `prove` hands each changed test it ran here, for the run's `prove.result` events.
    var proofs = ProveResultCollector()
    /// T3 hands each kept flow's record here, for the run's `qa.flow` events.
    var flows = FlowRecordCollector()
    /// Each brownfield area test step hands its totals here, for the run's `report.json`.
    var areaTests = AreaTestCountCollector()
  }

  /// - Parameters:
  ///   - steps: `ready` steps a lower `check` tier added, recorded in the run's history line.
  ///   - proofBases: the refs `prove` retried at, recorded in the run's history line.
  ///   - base: the ref `--base` named, resolved to a sha and recorded in the run's history line.
  ///   - checkTier: the `check` tier this run gates at, as its events' source.
  ///   - events: where the run's events go; `nil` asks `.swiftgate.toml`'s `[telemetry]`.
  ///   - workingTree: reads the tree the run starts on; `nil` asks git in `root`.
  ///   - reuseKey: the ``GateReuse`` key of a brownfield tier's inputs; `nil` always runs.
  static func execute(
    root: URL, format: OutputFormat, command: String, steps: [String]? = nil,
    proofBases: [String]? = nil, base: String? = nil, git: (any Git)? = nil,
    checkTier: CheckTier? = nil, events: (any HarnessEventWriting)? = nil,
    workingTree: (any WorkingTreeReading)? = nil, reuseKey: String? = nil,
    body: (Context) async throws -> GateRunParts
  ) async throws {
    if let reuseKey, let checkTier,
      try reuse(root: root, format: format, command: command, key: reuseKey, tier: checkTier)
    {
      return
    }
    let git = git ?? LiveGit(runner: LiveProcessRunner(), repositoryRoot: root.path)
    let clock = ContinuousClock()
    let startedAt = Date()
    let start = clock.now
    let runID = RunID.make(startedAt: startedAt, suffix: UInt32.random(in: .min ... .max))
    let directory: URL
    do {
      directory = try RunStore(worktreeRoot: root).runDirectory(for: runID)
    } catch {
      // Artifacts are diagnostics; without the run directory they go to a temporary one.
      directory = FileManager.default.temporaryDirectory.appending(
        path: "swiftgate-\(runID)", directoryHint: .isDirectory)
    }
    // Belt and braces beside every invocation's own --only-use-versions-from-resolved-file /
    // -onlyUsePackageVersionsFromResolvedFile: whatever `body` runs must never rewrite a committed
    // Package.resolved, on any path those flags missed.
    let resolvedFilesBefore = await ResolvedFileGuard.snapshot(root: root, git: git)
    let headCommit = await headCommit(git: git)
    let resolvedBase = await resolved(base: base, git: git)
    let telemetry = await telemetry(root: root, events: events, workingTree: workingTree)
    let context = Context(
      runID: runID, directory: directory, steps: GateStepCollector(startedAt: start))
    var parts = try await body(context)
    let resolvedFilesAfter = await ResolvedFileGuard.snapshot(root: root, git: git)
    if let finding = try ResolvedFileGuard.finding(
      before: resolvedFilesBefore, after: resolvedFilesAfter)
    {
      parts.findings.append(finding)
    }
    let report = try RunReport(
      runID: runID, durationMilliseconds: milliseconds(clock.now - start), tiers: parts.tiers,
      findings: parts.findings, allowances: parts.allowances)
    record { () throws(RunStoreError) in
      try RunStore(worktreeRoot: root, events: telemetry.events).record(
        report, finishedAt: Date(), command: command, steps: steps, proofBases: proofBases,
        headCommit: headCommit, base: resolvedBase, treeHash: telemetry.tree?.treeHash,
        dirty: telemetry.tree?.dirty, gateSteps: context.steps.steps, checkTier: checkTier,
        testResults: context.tests.cases, baselineCount: parts.baselineCount,
        proofs: context.proofs.results, flows: context.flows.flows,
        reuseKey: telemetry.tree?.dirty == false ? reuseKey : nil,
        areaTests: context.areaTests.all)
    }
    Console.write(
      try ReportRenderer.render(
        report, format: format, state: StateRootResolver.resolve(worktree: root)))
    let status = report.verdict.exitCode
    if status != 0 { throw ExitCode(status) }
  }

  /// Prints the newest GREEN run recorded with `key`, with a `gate.reused` note naming it, and
  /// records nothing: the inputs it ran on are the same, so its verdict stands. `false` when no
  /// such run, or its report, can be read.
  static func reuse(
    root: URL, format: OutputFormat, command: String, key: String, tier: CheckTier
  ) throws -> Bool {
    let store = RunStore(worktreeRoot: root)
    guard let records = try? store.readHistory().records,
      let prior = GateReuse.reusable(records, command: command, key: key),
      let data = try? Data(
        contentsOf: store.state.url(RunLayout.runDirectory(for: prior.runID))
          .appending(path: RunLayout.reportFileName)),
      let recorded = try? RecordedRunReport.decode(data)
    else { return false }
    let note = try Finding(
      ruleID: GateReuse.ruleID, severity: .nit, file: ".", line: nil,
      message:
        "check --tier \(tier.rawValue) reused GREEN run \(prior.runID): the same tree, merge "
        + "base, swiftgate build and clone config, baseline and warm-up times; nothing re-ran",
      failureScenario: nil)
    let report = try RunReport(
      runID: recorded.report.runID, durationMilliseconds: recorded.report.durationMilliseconds,
      tiers: recorded.report.tiers, findings: recorded.report.findings + [note],
      allowances: recorded.report.allowances)
    Console.write(
      try ReportRenderer.render(
        report, format: format, state: StateRootResolver.resolve(worktree: root)))
    let status = report.verdict.exitCode
    if status != 0 { throw ExitCode(status) }
    return true
  }

  /// Where a run's events go, and the tree it starts on. `events` stands in for the project's
  /// writer; without it, a root with no loadable `.swiftgate.toml` gets no writer, and
  /// `[telemetry] enabled = false` gets one that keeps nothing. The tree is read whatever the
  /// writer, since the run's history line records whether it was dirty and `build check-return`
  /// rejects a gate that was; a git failure says so on stderr and leaves it unknown.
  static func telemetry(
    root: URL, events: (any HarnessEventWriting)?, workingTree: (any WorkingTreeReading)?
  ) async -> (events: (any HarnessEventWriting)?, tree: WorkingTreeState?) {
    let writer: (any HarnessEventWriting)?
    if let events {
      writer = events
    } else {
      writer = TelemetryOptIn.writer(root: root)
    }
    let reader = workingTree ?? LiveWorkingTree(runner: LiveProcessRunner(), root: root)
    do {
      return (writer, try await reader.state())
    } catch {
      FileHandle.standardError.write(
        Data("swiftgate: could not read the working tree to record with the run: \(error)\n".utf8))
      return (writer, nil)
    }
  }

  /// Runs `write`, a run's record. A failure prints 1 line and never changes the run's verdict:
  /// the record is diagnostics, and its events more so.
  static func record(_ write: () throws(RunStoreError) -> Void) {
    do throws(RunStoreError) {
      try write()
    } catch .eventsUnwritten(let failure) {
      FileHandle.standardError.write(
        Data("swiftgate: gate events not written: \(failure)\n".utf8))
    } catch {
      FileHandle.standardError.write(Data("swiftgate: could not record run: \(error)\n".utf8))
    }
  }

  /// The commit the run starts at, so its report and history line name what it gated. `nil` in a
  /// checkout with no commit yet; a git failure says so on stderr rather than going unrecorded.
  private static func headCommit(git: any Git) async -> String? {
    do {
      return try await git.revision("HEAD")
    } catch {
      FileHandle.standardError.write(
        Data("swiftgate: could not read HEAD to record with the run: \(error)\n".utf8))
      return nil
    }
  }

  /// The sha `base` names, so a reader can tell what the run's diff was measured from. `nil` with
  /// no base, or when it names no commit or git fails, which stderr says rather than going
  /// unrecorded.
  private static func resolved(base: String?, git: any Git) async -> String? {
    guard let base else { return nil }
    do {
      if let sha = try await git.revision(base) { return sha }
      FileHandle.standardError.write(
        Data("swiftgate: --base \(base) names no commit to record with the run\n".utf8))
    } catch {
      FileHandle.standardError.write(
        Data("swiftgate: could not resolve --base \(base) to record with the run: \(error)\n".utf8))
    }
    return nil
  }

  static func milliseconds(_ duration: Duration) -> Int {
    Int(duration.components.seconds * 1000)
      + Int(duration.components.attoseconds / 1_000_000_000_000_000)
  }

  /// Times `body` on a continuous clock.
  static func timed<T>(_ body: () async throws -> T) async rethrows -> (T, Int) {
    let clock = ContinuousClock()
    let start = clock.now
    let value = try await body()
    return (value, milliseconds(clock.now - start))
  }
}

/// The test cases 1 gate run's tiers reported, in the order the tiers handed them over. Tiers
/// can finish on several tasks, so recording is locked.
final class TestResultCollector: Sendable {
  private let results = Mutex<[TestCaseResult]>([])

  init() {}

  func record(_ cases: [TestCaseResult]) {
    results.withLock { $0.append(contentsOf: cases) }
  }

  var cases: [TestCaseResult] { results.withLock { $0 } }
}

/// The totals of 1 gate run's area test steps. Areas run on several tasks, so recording is locked,
/// and they come back by area then step, whatever order the steps finished in.
final class AreaTestCountCollector: Sendable {
  private let counts = Mutex<[AreaTestCounts]>([])

  init() {}

  func record(_ counted: AreaTestCounts) {
    counts.withLock { $0.append(counted) }
  }

  var all: [AreaTestCounts] {
    let order = AreaStep.allCases
    return counts.withLock { $0 }.sorted {
      ($0.area, order.firstIndex(of: $0.step) ?? 0) < ($1.area, order.firstIndex(of: $1.step) ?? 0)
    }
  }
}

/// The kept flows 1 gate run's T3 recorded, in the order it handed them over.
final class FlowRecordCollector: Sendable {
  private let records = Mutex<[QAFlowRecord]>([])

  init() {}

  func record(_ flows: [QAFlowRecord]) {
    records.withLock { $0.append(contentsOf: flows) }
  }

  var flows: [QAFlowRecord] { records.withLock { $0 } }
}

/// The changed tests 1 gate run's `prove` ran, in the order it handed them over.
final class ProveResultCollector: Sendable {
  private let proved = Mutex<[ProvedTest]>([])

  init() {}

  func record(_ results: [ProvedTest]) {
    proved.withLock { $0.append(contentsOf: results) }
  }

  var results: [ProvedTest] { proved.withLock { $0 } }
}

/// Paths changed since a ref, relative to this project's root (which may sit inside a larger
/// repository).
enum ChangedPaths {
  static func since(_ ref: String, git: any Git) async throws(GitError) -> [String] {
    let prefix = try await git.workingDirectoryPrefix()
    return try await git.changedFiles(since: ref)
      .filter { $0.hasPrefix(prefix) }
      .map { String($0.dropFirst(prefix.count)) }
  }
}

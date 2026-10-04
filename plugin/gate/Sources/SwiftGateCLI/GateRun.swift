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
  }

  /// - Parameters:
  ///   - steps: `ready` steps a lower `check` tier added, recorded in the run's history line.
  ///   - proofBases: the refs `prove` retried at, recorded in the run's history line.
  ///   - base: the ref `--base` named, resolved to a sha and recorded in the run's history line.
  ///   - checkTier: the `check` tier this run gates at, as its events' source.
  ///   - events: where the run's events go; `nil` asks `.swiftgate.toml`'s `[telemetry]`.
  ///   - workingTree: reads the tree the run starts on; `nil` asks git in `root`.
  static func execute(
    root: URL, format: OutputFormat, command: String, steps: [String]? = nil,
    proofBases: [String]? = nil, base: String? = nil, git: (any Git)? = nil,
    checkTier: CheckTier? = nil, events: (any HarnessEventWriting)? = nil,
    workingTree: (any WorkingTreeReading)? = nil,
    body: (Context) async throws -> GateRunParts
  ) async throws {
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
    let context = Context(runID: runID, directory: directory)
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
        testResults: context.tests.cases)
    }
    Console.write(
      try ReportRenderer.render(
        report, format: format, state: StateRootResolver.resolve(worktree: root)))
    let status = report.verdict.exitCode
    if status != 0 { throw ExitCode(status) }
  }

  /// Where a run's events go, and the tree it starts on. `events` stands in for the project's
  /// writer; without it, a root with no loadable `.swiftgate.toml` gets no writer, and
  /// `[telemetry] enabled = false` gets one that keeps nothing. The tree is read only for a
  /// writer that keeps events; a git failure says so on stderr and leaves it unknown.
  static func telemetry(
    root: URL, events: (any HarnessEventWriting)?, workingTree: (any WorkingTreeReading)?
  ) async -> (events: (any HarnessEventWriting)?, tree: WorkingTreeState?) {
    let writer: (any HarnessEventWriting)?
    if let events {
      writer = events
    } else if case .success(let config?) = StaticCheckInputs.loadConfig(root: root) {
      writer = EventWriterFactory.make(root: root, enabled: config.telemetry.enabled)
    } else {
      writer = nil
    }
    guard let writer, !(writer is DisabledEventWriter) else { return (writer, nil) }
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

import Darwin
import Foundation
import SwiftGateDomain

public enum RunStoreError: Error, Sendable, Equatable {
  case invalidRunID(String)
  case io(operation: String, path: String, reason: String)
  /// The run's report and history line were written; its events weren't.
  case eventsUnwritten(HarnessEventWriteError)

  public var verdict: Verdict { .blocked }
}

/// What ``RunStore/keepRuns(in:)`` copied, and each run it couldn't with the reason.
public struct RunKeepOutcome: Sendable, Equatable {
  public struct Unkept: Sendable, Equatable {
    public let runID: String
    public let reason: String

    public init(runID: String, reason: String) {
      self.runID = runID
      self.reason = reason
    }
  }

  /// Run ids now in the destination, sorted.
  public let kept: [String]
  public let unkept: [Unkept]

  public init(kept: [String], unkept: [Unkept]) {
    self.kept = kept
    self.unkept = unkept
  }
}

/// Persists runs under a worktree's state root's `runs/`: one directory per run holding its logs and
/// `report.json`, plus the shared `history.jsonl`. With an event writer, each record also writes
/// the run's `gate.run`, its `gate.step`s and its `test.result`s.
public struct RunStore: Sendable {
  public let worktreeRoot: URL
  public let state: StateRoot
  /// `nil` records no events.
  public let events: (any HarnessEventWriting)?
  private let newEventID: @Sendable () -> String

  public init(
    worktreeRoot: URL, events: (any HarnessEventWriting)? = nil,
    newEventID: @escaping @Sendable () -> String = {
      UUID().uuidString  // swiftgate:allow det.uuid-init — an event id need only be unique
    }
  ) {
    self.worktreeRoot = worktreeRoot
    self.state = StateRootResolver.resolve(worktree: worktreeRoot)
    self.events = events
    self.newEventID = newEventID
  }

  public var historyFile: URL {
    state.url(RunLayout.historyFile, directoryHint: .notDirectory)
  }

  /// Creates (if needed) and returns the directory for `runID`, where a run writes its artifacts.
  public func runDirectory(for runID: String) throws(RunStoreError) -> URL {
    guard RunID.isValid(runID) else { throw .invalidRunID(runID) }
    let url = state.url(RunLayout.runDirectory(for: runID), directoryHint: .isDirectory)
    do {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    } catch {
      throw .io(operation: "mkdir", path: url.path, reason: error.localizedDescription)
    }
    return url
  }

  /// Writes the run's `report.json` and appends its summary to `history.jsonl`, then writes its
  /// events. Neither file changes with the events.
  /// - Parameters:
  ///   - headCommit: the commit `HEAD` was at when the run started, in both.
  ///   - treeHash: `HEAD^{tree}` when the run started on a clean tree, for the `gate.run` only.
  ///   - dirty: whether it started on a dirty tree; `nil` when git couldn't say.
  ///   - gateSteps: each timed step, 1 `gate.step` apiece.
  ///   - checkTier: the `check` tier the run gated at, as the events' source.
  ///   - testResults: each test case the run's tiers reported, 1 `test.result` apiece, in the
  ///     same batch as the run's other events.
  /// - Throws: ``RunStoreError/eventsUnwritten(_:)`` when only the events failed, after the run
  ///   is recorded.
  public func record(
    _ report: RunReport, finishedAt: Date, command: String? = nil, steps: [String]? = nil,
    proofBases: [String]? = nil, headCommit: String? = nil, base: String? = nil,
    treeHash: String? = nil, dirty: Bool? = nil, gateSteps: [GateStepTiming] = [],
    checkTier: CheckTier? = nil, testResults: [TestCaseResult] = []
  ) throws(RunStoreError) {
    let clock = ContinuousClock()
    let start = clock.now
    let directory = try runDirectory(for: report.runID)
    let reportFile = directory.appending(path: RunLayout.reportFileName)
    let reportData: Data
    let line: Data
    do {
      reportData = try RecordedRunReport.encode(
        RecordedRunReport(report: report, headCommit: headCommit))
      line = try RunHistoryJSON.encodeLine(
        RunHistoryRecord(
          report: report, finishedAt: finishedAt, command: command, steps: steps,
          proofBases: proofBases, headCommit: headCommit, base: base))
    } catch {
      throw .io(operation: "encode", path: reportFile.path, reason: String(describing: error))
    }
    do {
      try reportData.write(to: reportFile, options: .atomic)
    } catch {
      throw .io(operation: "write", path: reportFile.path, reason: error.localizedDescription)
    }
    try append(line, to: historyFile.path)
    guard let events else { return }
    let elapsed = (clock.now - start).components
    let recordStep = GateStepTiming(
      step: .record, tier: nil,
      milliseconds: Int(elapsed.seconds * 1000)
        + Int(elapsed.attoseconds / 1_000_000_000_000_000),
      verdict: .green, derivedData: .none)
    do throws(HarnessEventWriteError) {
      try events.append(
        contentsOf: try gateEvents(
          report, finishedAt: finishedAt, command: command, headCommit: headCommit, base: base,
          treeHash: treeHash, dirty: dirty, steps: gateSteps + [recordStep],
          checkTier: checkTier, testResults: testResults))
    } catch {
      throw .eventsUnwritten(error)
    }
  }

  /// The run's `gate.run`, then each step's `gate.step` and each case's `test.result` pointing
  /// at it.
  private func gateEvents(
    _ report: RunReport, finishedAt: Date, command: String?, headCommit: String?, base: String?,
    treeHash: String?, dirty: Bool?, steps: [GateStepTiming], checkTier: CheckTier?,
    testResults: [TestCaseResult]
  ) throws(HarnessEventWriteError) -> [HarnessEvent] {
    let payload: GateRunEvent
    do {
      payload = try GateRunEvent(report: report, command: command, treeHash: treeHash, dirty: dirty)
    } catch {
      throw HarnessEventWriteError(
        path: state.displayPath(RunLayout.eventsFile(.gate)), reason: "gate.run: \(error)")
    }
    let source = HarnessEventSource(route: .check, tier: checkTier)
    let run = HarnessEvent(
      eventID: newEventID(), time: finishedAt, runID: report.runID, head: headCommit, base: base,
      source: source, payload: .gateRun(payload))
    func child(_ payload: HarnessEventPayload) -> HarnessEvent {
      HarnessEvent(
        eventID: newEventID(), parentID: run.eventID, time: finishedAt, runID: report.runID,
        head: headCommit, base: base, source: source, payload: payload)
    }
    return [run] + steps.map { child(.gateStep(GateStepEvent($0))) }
      + testResults.map { child(.testResult(TestResultEvent($0))) }
  }

  public func readHistory() throws(RunStoreError) -> (
    records: [RunHistoryRecord], invalidLines: Int
  ) {
    let data: Data
    do {
      data = try Data(contentsOf: historyFile)
    } catch CocoaError.fileReadNoSuchFile {
      return ([], 0)
    } catch {
      throw .io(operation: "read", path: historyFile.path, reason: error.localizedDescription)
    }
    return RunHistoryJSON.decode(data)
  }

  /// Copies every run directory under this store into `destination`'s runs, so a worktree's gate
  /// reports outlive it. The history file stays behind: the destination's own history counts only
  /// its own runs. A run already in `destination` counts as kept, since run ids are unique.
  /// - Throws: when this store's runs directory exists but can't be listed.
  public func keepRuns(in destination: RunStore) throws(RunStoreError) -> RunKeepOutcome {
    let files = FileManager.default
    let source = state.url(RunLayout.runsDirectory, directoryHint: .isDirectory)
    let names: [String]
    do {
      names = try files.contentsOfDirectory(atPath: source.path)
    } catch CocoaError.fileReadNoSuchFile {
      return RunKeepOutcome(kept: [], unkept: [])
    } catch {
      throw .io(operation: "list", path: source.path, reason: error.localizedDescription)
    }
    var kept: [String] = []
    var unkept: [RunKeepOutcome.Unkept] = []
    for runID in names.sorted() where RunID.isValid(runID) {
      let from = source.appending(path: runID, directoryHint: .isDirectory)
      var isDirectory: ObjCBool = false
      guard files.fileExists(atPath: from.path, isDirectory: &isDirectory), isDirectory.boolValue
      else { continue }
      let to = destination.state.url(
        RunLayout.runDirectory(for: runID), directoryHint: .isDirectory)
      var destinationIsDirectory: ObjCBool = false
      if files.fileExists(atPath: to.path, isDirectory: &destinationIsDirectory),
        destinationIsDirectory.boolValue
      {
        kept.append(runID)
        continue
      }
      do {
        try files.createDirectory(
          at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.copyItem(at: from, to: to)
        kept.append(runID)
      } catch {
        unkept.append(.init(runID: runID, reason: error.localizedDescription))
      }
    }
    return RunKeepOutcome(kept: kept, unkept: unkept)
  }

  /// Several sessions can share a worktree, so each record is 1 append-only line.
  private func append(_ line: Data, to path: String) throws(RunStoreError) {
    do throws(AppendOnlyFile.Failure) {
      try AppendOnlyFile.append(line, to: path)
    } catch {
      throw .io(operation: error.operation, path: path, reason: error.detail)
    }
  }
}

/// Reads the state of the working tree a run starts on.
public protocol WorkingTreeReading: Sendable {
  func state() async throws(GitError) -> WorkingTreeState
}

/// ``WorkingTreeReading`` over `git status --porcelain` and `git rev-parse HEAD^{tree}`.
public struct LiveWorkingTree: WorkingTreeReading {
  /// The harness's own state is never source and can't change a build, so anything under a
  /// `.harness/` directory, at any depth, leaves the tree clean.
  static let harnessStateExcluded = ":(exclude,glob)**/\(RunLayout.treeDirectory)/**"

  private let runner: any ProcessRunner
  private let root: URL

  public init(runner: any ProcessRunner, root: URL) {
    self.runner = runner
    self.root = root
  }

  public func state() async throws(GitError) -> WorkingTreeState {
    let status = try await git([
      "status", "--porcelain", "-z", "--untracked-files=normal", "--", Self.harnessStateExcluded,
    ])
    guard status.status.isSuccess else { throw Self.failure(status) }
    if !status.stdout.bytes.isEmpty { return WorkingTreeState(treeHash: nil, dirty: true) }
    let tree = try await git(["rev-parse", "--verify", "--quiet", "HEAD^{tree}"])
    // `--quiet` makes a HEAD with no commit yet exit 1 with no diagnostics.
    if tree.status == .exited(1), tree.stderr.bytes.isEmpty {
      return WorkingTreeState(treeHash: nil, dirty: false)
    }
    guard tree.status.isSuccess else { throw Self.failure(tree) }
    return WorkingTreeState(
      treeHash: tree.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines), dirty: false)
  }

  private struct Output {
    let arguments: [String]
    let status: ExitStatus
    let stdout: CapturedStream
    let stderr: CapturedStream
  }

  /// `GIT_OPTIONAL_LOCKS=0` keeps `status` from refreshing the index under `index.lock`, which
  /// a concurrent git command in the same worktree would contend on.
  private func git(_ arguments: [String]) async throws(GitError) -> Output {
    do {
      let output = try await runner.run(
        ProcessInvocation(
          executable: "git", arguments: arguments,
          environmentOverlay: [
            "LC_ALL": "C", "GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0",
          ],
          workingDirectory: root.path, timeout: .seconds(60)))
      return Output(
        arguments: arguments, status: output.status, stdout: output.stdout, stderr: output.stderr)
    } catch {
      throw .process(error)
    }
  }

  private static func failure(_ output: Output) -> GitError {
    .commandFailed(arguments: output.arguments, status: output.status, stderr: output.stderr.text)
  }
}

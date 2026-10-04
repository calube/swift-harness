import Foundation
import SwiftGateDomain

/// What a judged `sim verify` returns: the report, and each record it couldn't write.
public struct SimVerified: Sendable, Equatable {
  public var report: SimVerifyReport
  /// 1 line per file the run's record couldn't be written to. A record failure never changes
  /// the verdict; the caller prints these.
  public var unrecorded: [String]

  public init(report: SimVerifyReport, unrecorded: [String]) {
    self.report = report
    self.unrecorded = unrecorded
  }
}

/// What `swiftgate sim verify` does: resolve the run and refuse another worktree's, load its
/// `sim/` folder, apply ``SimEvidenceRules``, and write `sim/report.json` and a history line.
public struct SimVerify: Sendable {
  public struct Request: Sendable {
    /// The caller's canonical worktree root.
    public var worktree: String
    /// `nil` takes the caller's newest live lease.
    public var runID: String?
    public var checkoutHead: SimCheckoutHead
    /// The run's `sim/` folder for a run id, in the caller's state root.
    public var simDirectory: @Sendable (String) -> URL
    /// The state root's `runs/history.jsonl`.
    public var historyFile: URL

    public init(
      worktree: String, runID: String?, checkoutHead: SimCheckoutHead,
      simDirectory: @escaping @Sendable (String) -> URL, historyFile: URL
    ) {
      self.worktree = worktree
      self.runID = runID
      self.checkoutHead = checkoutHead
      self.simDirectory = simDirectory
      self.historyFile = historyFile
    }
  }

  public struct Dependencies: Sendable {
    public var leases: SimLeaseStore
    public var isAlive: @Sendable (Int32) -> Bool
    public var clock: SimHoldClock
    /// The history line's `finishedAt`.
    public var now: @Sendable () -> Date

    public init(
      leases: SimLeaseStore, isAlive: @escaping @Sendable (Int32) -> Bool, clock: SimHoldClock,
      now: @escaping @Sendable () -> Date
    ) {
      self.leases = leases
      self.isAlive = isAlive
      self.clock = clock
      self.now = now
    }
  }

  private let dependencies: Dependencies

  public init(dependencies: Dependencies) {
    self.dependencies = dependencies
  }

  public func run(_ request: Request) -> Result<SimVerified, SimVerifyFailure> {
    let runID: String
    do throws(SimVerifyFailure) {
      runID = try resolve(request)
    } catch {
      return .failure(error)
    }
    let start = dependencies.clock.now()
    let store = SimRunStore(simDirectory: request.simDirectory(runID))
    let report = judge(runID: runID, store: store, checkoutHead: request.checkoutHead)
    let unrecorded = record(
      report, store: store, historyFile: request.historyFile,
      elapsed: dependencies.clock.now() - start)
    return .success(SimVerified(report: report, unrecorded: unrecorded))
  }

  /// The named run, refused when a lease shows another worktree holds it, or the caller's newest
  /// live lease. A named run with no lease, as after `sim down`, is judged from its folder.
  private func resolve(_ request: Request) throws(SimVerifyFailure) -> String {
    if let runID = request.runID {
      guard SimLease.isValidRunID(runID) else {
        throw SimVerifyFailure(rule: .environment, message: "\"\(runID)\" is not a run id")
      }
      let lease: SimLease?
      do {
        lease = try dependencies.leases.read(runID: runID)
      } catch {
        throw SimVerifyFailure(rule: .environment, message: error.message, runID: runID)
      }
      if let lease,
        case .otherWorktree(let owner) = SimLease.owner(
          of: lease, callerWorktree: request.worktree)
      {
        throw SimVerifyFailure(
          rule: .notOwner,
          message: "run \(runID) belongs to the worktree at \(owner), not \(request.worktree)",
          runID: runID)
      }
      return runID
    }
    let listing: SimLeaseListing
    do {
      listing = try dependencies.leases.all()
    } catch {
      throw SimVerifyFailure(rule: .environment, message: error.message)
    }
    let own = listing.leases.filter {
      SimLease.owner(of: $0, callerWorktree: request.worktree) == .owner
        && dependencies.isAlive($0.holderPID)
    }
    // Run ids start with their UTC start time, so the greatest is the newest.
    guard let newest = own.max(by: { $0.runID < $1.runID }) else {
      let unreadable =
        listing.unreadable.isEmpty
        ? ""
        : "; unreadable leases: " + listing.unreadable.map(\.message).joined(separator: "; ")
      throw SimVerifyFailure(
        rule: .environment,
        message: "no live sim run for \(request.worktree); pass the run id sim up printed"
          + unreadable)
    }
    return newest.runID
  }

  private func judge(runID: String, store: SimRunStore, checkoutHead: SimCheckoutHead)
    -> SimVerifyReport
  {
    do throws(SimRunStoreError) {
      return .judged(
        try Self.evidence(runID: runID, store: store), checkoutHead: checkoutHead)
    } catch {
      return .unreadable(runID: runID, reason: error.message, checkoutHead: checkoutHead)
    }
  }

  /// The run's `sim/` folder at `simDirectory`, loaded: its session, its step log, and each file
  /// a step names inside the folder. A file that isn't on disk has no entry.
  public static func evidence(runID: String, simDirectory: URL) throws(SimRunStoreError)
    -> SimEvidence
  {
    try evidence(runID: runID, store: SimRunStore(simDirectory: simDirectory))
  }

  private static func evidence(runID: String, store: SimRunStore) throws(SimRunStoreError)
    -> SimEvidence
  {
    let session = try store.session()
    let steps = try store.steps()
    var files: [String: SimEvidenceFile] = [:]
    for path in steps.flatMap({ [$0.screenshot, $0.tree] }) where SimEvidence.isInsideRun(path) {
      do {
        files[path] = .present(try Data(contentsOf: store.simDirectory.appending(path: path)))
      } catch CocoaError.fileReadNoSuchFile {
        continue
      } catch {
        files[path] = .unreadable(error.localizedDescription)
      }
    }
    return SimEvidence(runID: runID, session: session, steps: steps, files: files)
  }

  /// Writes `sim/report.json` and appends the history line; returns 1 line per failure. The run's
  /// folder is never created, so a run that isn't there gets only its history line.
  private func record(
    _ report: SimVerifyReport, store: SimRunStore, historyFile: URL, elapsed: Duration
  ) -> [String] {
    var unrecorded: [String] = []
    let reportFile = store.simDirectory.appending(path: SimVerifyReport.fileName)
    do {
      try report.json().write(to: reportFile, options: .atomic)
    } catch {
      unrecorded.append("write \(reportFile.path): \(error.localizedDescription)")
    }
    let (seconds, attoseconds) = elapsed.components
    let milliseconds = Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    do {
      let line = try RunHistoryJSON.encodeLine(
        RunHistoryRecord(
          report: try report.runReport(durationMilliseconds: max(0, milliseconds)),
          finishedAt: dependencies.now(), command: SimVerifyReport.command,
          headCommit: report.checkoutHead))
      try AppendOnlyFile.append(line, to: historyFile.path, creatingDirectory: true)
    } catch let failure as AppendOnlyFile.Failure {
      unrecorded.append("append \(historyFile.path): \(failure.reason)")
    } catch {
      unrecorded.append("encode the history line for \(historyFile.path): \(error)")
    }
    return unrecorded
  }
}

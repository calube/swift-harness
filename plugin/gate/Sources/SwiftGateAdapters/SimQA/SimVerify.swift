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
    .failure(SimVerifyFailure(rule: .environment, message: "sim verify judges nothing yet"))
  }
}

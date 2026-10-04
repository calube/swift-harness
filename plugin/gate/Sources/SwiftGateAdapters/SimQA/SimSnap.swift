import Foundation
import SwiftGateDomain

/// What `swiftgate sim snap` does: resolve the run's lease and refuse another worktree's, take a
/// snapshot, a screenshot and a second snapshot on the run's `agent-device` session, and record
/// them as the run's next step.
public struct SimSnap: Sendable {
  public struct Request: Sendable {
    /// The caller's canonical worktree root.
    public var worktree: String
    /// `nil` takes the caller's newest live lease.
    public var runID: String?
    public var label: String
    public var assert: String?
    /// The run's `sim/` folder for a run id, in the caller's state root.
    public var simDirectory: @Sendable (String) -> URL

    public init(
      worktree: String, runID: String?, label: String, assert: String?,
      simDirectory: @escaping @Sendable (String) -> URL
    ) {
      self.worktree = worktree
      self.runID = runID
      self.label = label
      self.assert = assert
      self.simDirectory = simDirectory
    }
  }

  public struct Dependencies: Sendable {
    public var agentDevice: any AgentDevice
    public var leases: SimLeaseStore
    public var isAlive: @Sendable (Int32) -> Bool
    public var clock: SimHoldClock

    public init(
      agentDevice: any AgentDevice, leases: SimLeaseStore,
      isAlive: @escaping @Sendable (Int32) -> Bool, clock: SimHoldClock
    ) {
      self.agentDevice = agentDevice
      self.leases = leases
      self.isAlive = isAlive
      self.clock = clock
    }
  }

  private let dependencies: Dependencies

  public init(dependencies: Dependencies) {
    self.dependencies = dependencies
  }

  public func run(_ request: Request) async -> Result<SimSnapped, SimSnapFailure> {
    do throws(SimSnapFailure) {
      return .success(try await snap(request))
    } catch {
      return .failure(error)
    }
  }

  private func snap(_ request: Request) async throws(SimSnapFailure) -> SimSnapped {
    let lease = try resolve(request)
    let runID = lease.runID
    if case .otherWorktree(let owner) = SimLease.owner(
      of: lease, callerWorktree: request.worktree)
    {
      throw SimSnapFailure(
        rule: .notOwner,
        message: "run \(runID) belongs to the worktree at \(owner), not \(request.worktree)",
        runID: runID)
    }
    guard dependencies.isAlive(lease.holderPID) else {
      throw SimSnapFailure(
        rule: .sessionGone,
        message:
          "the holder of run \(runID) (PID \(lease.holderPID)) has exited, so its simulator is "
          + "gone; run sim up again", runID: runID)
    }
    guard let session = lease.session else {
      throw SimSnapFailure(
        rule: .sessionGone,
        message: "sim up has not opened the app for run \(runID); wait for it or run sim up again",
        runID: runID)
    }

    let store = SimRunStore(simDirectory: request.simDirectory(runID))
    do {
      _ = try store.session()
    } catch {
      throw SimSnapFailure(rule: .environment, message: error.message, runID: runID)
    }
    let staging: SimStepStaging
    do {
      staging = try store.stage()
    } catch {
      throw SimSnapFailure(rule: .environment, message: error.message, runID: runID)
    }

    let target = AgentDeviceTarget(udid: lease.udid, session: session)
    let start = dependencies.clock.now()
    let tree: Data
    let after: Data
    do {
      tree = try await dependencies.agentDevice.snapshotJSON(on: target)
      try await dependencies.agentDevice.screenshot(to: staging.screenshot.path, on: target)
      after = try await dependencies.agentDevice.snapshotJSON(on: target)
    } catch {
      store.appendLog("sim snap: \(error.message)")
      // A read on an exited app fails; only appstate tells that apart from a driver failure.
      if (try? await dependencies.agentDevice.appState(on: target)) == .notRunning {
        throw await recordExit(
          request, runID: runID, store: store, staging: staging, target: target, start: start)
      }
      store.discard(staging)
      throw Self.failure(error, runID: runID, log: store.agentDeviceLog)
    }
    let appState: AgentDeviceAppState
    do {
      appState = try await dependencies.agentDevice.appState(on: target)
    } catch {
      store.discard(staging)
      store.appendLog("sim snap: \(error.message)")
      throw Self.failure(error, runID: runID, log: store.agentDeviceLog)
    }
    let elapsed = dependencies.clock.now() - start
    let settled = SimStep.settled(before: tree, after: after)

    let step: SimStep
    do {
      step = try store.commit(staging, treeJSON: tree) { n in
        SimStep(
          n: n, label: request.label, assert: request.assert,
          screenshot: SimStep.screenshotPath(n: n), tree: SimStep.treePath(n: n),
          settled: settled, elapsedMs: Self.milliseconds(elapsed), appState: appState.simAppState)
      }
    } catch {
      store.discard(staging)
      throw SimSnapFailure(rule: .environment, message: error.message, runID: runID)
    }
    if appState == .notRunning { throw Self.exited(step, runID: runID) }
    return SimSnapped(runID: runID, step: step, simDirectory: store.simDirectory.path)
  }

  /// Records a step for an app that isn't running: a fresh screenshot, no tree, and the state.
  /// Returns the failure to throw: `sim.app-exited` once the step is recorded.
  private func recordExit(
    _ request: Request, runID: String, store: SimRunStore, staging: SimStepStaging,
    target: AgentDeviceTarget, start: Duration
  ) async -> SimSnapFailure {
    do {
      try await dependencies.agentDevice.screenshot(to: staging.screenshot.path, on: target)
    } catch {
      store.discard(staging)
      store.appendLog("sim snap: \(error.message)")
      return Self.failure(error, runID: runID, log: store.agentDeviceLog)
    }
    let elapsed = dependencies.clock.now() - start
    do {
      let step = try store.commit(staging, treeJSON: nil) { n in
        SimStep(
          n: n, label: request.label, assert: request.assert,
          screenshot: SimStep.screenshotPath(n: n), tree: nil, settled: nil,
          elapsedMs: Self.milliseconds(elapsed), appState: .notRunning)
      }
      return Self.exited(step, runID: runID)
    } catch {
      store.discard(staging)
      return SimSnapFailure(rule: .environment, message: error.message, runID: runID)
    }
  }

  private static func exited(_ step: SimStep, runID: String) -> SimSnapFailure {
    SimSnapFailure(
      rule: .appExited,
      message: "run \(runID) step \(SimStep.stem(step.n)) \"\(step.label)\": the app is not "
        + "running, so it exited or crashed; the step is recorded for sim verify, and sim down "
        + "copies the crash report into \(SimSession.directoryName)/\(SimCrashReport.directoryName)/",
      runID: runID)
  }

  /// The named run's lease, or the caller's newest one whose holder is alive.
  private func resolve(_ request: Request) throws(SimSnapFailure) -> SimLease {
    if let runID = request.runID {
      let lease: SimLease?
      do {
        lease = try dependencies.leases.read(runID: runID)
      } catch {
        throw SimSnapFailure(rule: .environment, message: error.message, runID: runID)
      }
      guard let lease else {
        throw SimSnapFailure(
          rule: .sessionGone,
          message: "run \(runID) holds no simulator: sim down or the holder released it; "
            + "run sim up again", runID: runID)
      }
      return lease
    }
    let listing: SimLeaseListing
    do {
      listing = try dependencies.leases.all()
    } catch {
      throw SimSnapFailure(rule: .environment, message: error.message)
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
      throw SimSnapFailure(
        rule: .sessionGone,
        message: "no live sim run for \(request.worktree); run sim up first\(unreadable)")
    }
    return newest
  }

  /// A device the CLI can no longer find is a gone session; any other failure is the driver's.
  private static func failure(_ error: AgentDeviceError, runID: String, log: URL)
    -> SimSnapFailure
  {
    if case .failed(_, let failure) = error, failure.code == .deviceNotFound {
      return SimSnapFailure(
        rule: .sessionGone,
        message: "the simulator of run \(runID) is gone: \(error.message); run sim up again",
        runID: runID)
    }
    return SimSnapFailure(
      rule: .driverFailed, message: "\(error.message); see \(log.path)", runID: runID)
  }

  private static func milliseconds(_ duration: Duration) -> Int {
    let (seconds, attoseconds) = duration.components
    return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
  }
}

extension AgentDeviceAppState {
  fileprivate var simAppState: SimAppState {
    switch self {
    case .unknown: .unknown
    case .notRunning: .notRunning
    case .runningBackgroundSuspended: .runningBackgroundSuspended
    case .runningBackground: .runningBackground
    case .runningForeground: .runningForeground
    }
  }
}

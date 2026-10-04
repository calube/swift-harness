import Foundation
import SwiftGateDomain

/// What `swiftgate sim down` does: resolve the run's lease and refuse another worktree's, close
/// the run's `agent-device` session, remove the lease so the holder gives the device back, wait
/// for the holder to exit and the device to go, then release `agent-device`'s stale claims on the
/// device. With no lease to release it does nothing and succeeds, so a second call is harmless.
public struct SimDown: Sendable {
  public struct Request: Sendable {
    /// The caller's canonical worktree root.
    public var worktree: String
    /// `nil` takes the caller's newest lease, live holder or not.
    public var runID: String?
    /// The run's `sim/` folder for a run id, in the caller's state root.
    public var simDirectory: @Sendable (String) -> URL

    public init(
      worktree: String, runID: String?, simDirectory: @escaping @Sendable (String) -> URL
    ) {
      self.worktree = worktree
      self.runID = runID
      self.simDirectory = simDirectory
    }
  }

  public struct Dependencies: Sendable {
    public var agentDevice: any AgentDevice
    public var leases: SimLeaseStore
    /// Lists devices to see the run's go, and deletes it when its holder died holding it.
    public var simctl: any Simctl
    public var isAlive: @Sendable (Int32) -> Bool
    public var clock: SimHoldClock
    /// How long to wait for the holder to exit and the device to go.
    public var teardownTimeout: Duration
    public var pollInterval: Duration

    public init(
      agentDevice: any AgentDevice, leases: SimLeaseStore, simctl: any Simctl,
      isAlive: @escaping @Sendable (Int32) -> Bool, clock: SimHoldClock,
      teardownTimeout: Duration = .seconds(120), pollInterval: Duration = .milliseconds(500)
    ) {
      self.agentDevice = agentDevice
      self.leases = leases
      self.simctl = simctl
      self.isAlive = isAlive
      self.clock = clock
      self.teardownTimeout = teardownTimeout
      self.pollInterval = pollInterval
    }
  }

  private let dependencies: Dependencies

  public init(dependencies: Dependencies) {
    self.dependencies = dependencies
  }

  public func run(_ request: Request) async -> Result<SimDowned, SimDownFailure> {
    do throws(SimDownFailure) {
      return .success(try await down(request))
    } catch {
      return .failure(error)
    }
  }

  private func down(_ request: Request) async throws(SimDownFailure) -> SimDowned {
    var notes: [String] = []
    guard let lease = try resolve(request, notes: &notes) else {
      return SimDowned(outcome: .nothingHeld(runID: request.runID), notes: notes)
    }
    let runID = lease.runID
    if case .otherWorktree(let owner) = SimLease.owner(
      of: lease, callerWorktree: request.worktree)
    {
      throw SimDownFailure(
        rule: .notOwner,
        message: "run \(runID) belongs to the worktree at \(owner), not \(request.worktree)",
        runID: runID)
    }
    let store = SimRunStore(simDirectory: request.simDirectory(runID))

    // The session goes first: `close` names the device, which is gone once the holder returns.
    var driverProblems: [String] = []
    if let session = lease.session {
      let target = AgentDeviceTarget(udid: lease.udid, session: session)
      if let problem = await close(target, notes: &notes) { driverProblems.append(problem) }
    }

    do {
      try dependencies.leases.remove(runID: runID)
    } catch {
      throw SimDownFailure(rule: .environment, message: error.message, runID: runID)
    }
    try await awaitTeardown(of: lease)

    do {
      try await dependencies.agentDevice.releaseStale(udid: lease.udid)
    } catch {
      driverProblems.append(error.message)
    }

    if !driverProblems.isEmpty {
      for problem in driverProblems { store.appendLog("sim down: \(problem)") }
      throw SimDownFailure(
        rule: .driverFailed,
        message: "run \(runID) gave back \(lease.udid), but "
          + driverProblems.joined(separator: "; ") + "; see \(store.agentDeviceLog.path)",
        runID: runID)
    }
    return SimDowned(outcome: .released(runID: runID, udid: lease.udid), notes: notes)
  }

  /// The named run's lease, or the caller's newest one whether or not its holder lives, so a
  /// lease a dead holder left is still torn down. `nil` when there is none.
  private func resolve(_ request: Request, notes: inout [String]) throws(SimDownFailure)
    -> SimLease?
  {
    if let runID = request.runID {
      do {
        return try dependencies.leases.read(runID: runID)
      } catch {
        throw SimDownFailure(rule: .environment, message: error.message, runID: runID)
      }
    }
    let listing: SimLeaseListing
    do {
      listing = try dependencies.leases.all()
    } catch {
      throw SimDownFailure(rule: .environment, message: error.message)
    }
    notes += listing.unreadable.map { "unreadable lease skipped: \($0.message)" }
    // Run ids start with their UTC start time, so the greatest is the newest.
    return listing.leases
      .filter { SimLease.owner(of: $0, callerWorktree: request.worktree) == .owner }
      .max { $0.runID < $1.runID }
  }

  /// Closes the session and checks `agent-device` no longer lists it. Returns the problem when
  /// the session may still be open; a session or device already gone counts as closed.
  private func close(_ target: AgentDeviceTarget, notes: inout [String]) async -> String? {
    do {
      try await dependencies.agentDevice.close(on: target)
    } catch {
      guard case .failed(_, let failure) = error,
        failure.code == .sessionNotFound || failure.code == .deviceNotFound
      else { return error.message }
      notes.append("session \(target.session) was already closed: \(error.message)")
    }
    let sessions: [AgentDeviceSession]
    do {
      sessions = try await dependencies.agentDevice.sessions(on: target)
    } catch {
      notes.append(
        "could not check that session \(target.session) closed: \(error.message)")
      return nil
    }
    guard sessions.contains(where: { $0.name == target.session }) else { return nil }
    return "agent-device still lists session \(target.session) after close"
  }

  /// Waits until the holder has exited and the device is gone. A holder that died without
  /// deleting its device leaves one named for its dead PID; that device, and no other, is
  /// deleted here.
  private func awaitTeardown(of lease: SimLease) async throws(SimDownFailure) {
    let start = dependencies.clock.now()
    var lastProblem: String?
    while true {
      let holderAlive = dependencies.isAlive(lease.holderPID)
      // `nil` when the listing failed, so whether the device is there isn't known this round.
      var deviceExists: Bool?
      do {
        let device = try await dependencies.simctl.devices().first { $0.udid == lease.udid }
        deviceExists = device != nil
        if !holderAlive, let device,
          !SimulatorSelection.orphans(in: [device], isAlive: dependencies.isAlive).isEmpty
        {
          // `simctl delete` refuses a booted device; shutting down a shut-down one fails harmlessly.
          try? await dependencies.simctl.shutdown(device.udid)
          try await dependencies.simctl.delete(device.udid)
          deviceExists = false
        }
      } catch {
        lastProblem = "\(error)"
      }
      if !holderAlive && deviceExists == false { return }
      if dependencies.clock.now() - start >= dependencies.teardownTimeout {
        let holder =
          holderAlive ? "holder PID \(lease.holderPID) is still running" : "the holder exited"
        let device =
          switch deviceExists {
          case false?: "the device is gone"
          case true?: "device \(lease.udid) still exists"
          case nil: "device \(lease.udid) could not be listed"
          }
        let detail = lastProblem.map { "; last simctl error: \($0)" } ?? ""
        throw SimDownFailure(
          rule: .environment,
          message: "run \(lease.runID) did not finish releasing within "
            + "\(dependencies.teardownTimeout.components.seconds) s: \(holder), \(device)\(detail)",
          runID: lease.runID)
      }
      do {
        try await dependencies.clock.sleep(dependencies.pollInterval)
      } catch {
        throw SimDownFailure(
          rule: .environment,
          message: "sim down was cancelled while run \(lease.runID) was releasing",
          runID: lease.runID)
      }
    }
  }
}

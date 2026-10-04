import ArgumentParser
import Darwin
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// The detached process `sim up` starts to own a run's simulator until `sim down`, the end of
/// the run's `agent-device` session, or `[qa] session_timeout_minutes`. Not for direct use: it
/// takes the worktree it runs in as the lease's owner, so `sim up` starts it in the worktree root.
struct SimHoldCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "hold",
    abstract: "Hold one simulator slot and device for a QA run (started by sim up).",
    shouldDisplay: false)

  @Option(name: .customLong("run"), help: "The run id the lease is written under.")
  var runID: String

  func validate() throws {
    guard SimLease.isValidRunID(runID) else {
      throw ValidationError(
        "--run \"\(runID)\" is not a run id: use letters, digits, '-', '_' and '.', not leading '.'"
      )
    }
  }

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let runner = LiveProcessRunner()
    let target: SimTarget
    let simulator: SimulatorConfig
    do throws(SimUpFailure) {
      target = try SimTargetLoader.load(worktree: root).get()
      simulator = try await SimTargetLoader.simulator(
        for: target,
        simctl: LiveSimctl(
          runner: runner,
          timeouts: LiveSimctl.Timeouts(quick: .seconds(target.simctlTimeoutSeconds)))
      ).get()
    } catch {
      Self.log("sim hold: \(error.message)")
      throw ExitCode(error.verdict.exitCode)
    }
    let holder = SimHolder(
      devices: SimulatorClones.live(
        config: simulator, runner: runner,
        releaseClaims: SimulatorClones.agentDeviceClaimRelease(
          LiveAgentDevice(runner: runner), failed: { Self.log("sim hold: \($0)") })),
      leases: SimLeaseStore(directory: SimLeaseStore.defaultDirectory()),
      agentDevice: LiveAgentDevice(runner: runner), worktree: CanonicalPath.of(root),
      holderPID: getpid(), timeout: .seconds(target.sessionTimeoutMinutes * 60),
      log: Self.log)
    do {
      _ = try await holder.hold(runID: runID)
    } catch let error as SimulatorCloneError {
      Self.log("sim hold: no device for run \(runID): \(error)")
      throw ExitCode(error.verdict.exitCode)
    } catch let error as SimLeaseStoreError {
      Self.log("sim hold: \(error.message)")
      throw ExitCode(Verdict.blocked.exitCode)
    }
  }

  /// Unbuffered, so `agent-device.log` shows each line even if the holder is killed.
  @Sendable static func log(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
  }
}

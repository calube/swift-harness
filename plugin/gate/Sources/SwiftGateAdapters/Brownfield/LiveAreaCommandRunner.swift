import Foundation
import SwiftGateDomain

/// Runs an area command through `/bin/sh -c` in the area root, with stderr folded into stdout so
/// the tail keeps the order the runner printed in.
public struct LiveAreaCommandRunner: AreaCommandRunning {
  private let processRunner: any ProcessRunner
  private let seeding: DerivedDataSeeding

  /// - Parameter processRunner: leads each command's own process group, so a timeout kills
  ///   every process the command started.
  public init(processRunner: any ProcessRunner = LiveProcessRunner()) {
    self.processRunner = processRunner
    seeding = DerivedDataSeeding(processRunner: processRunner)
  }

  /// A seed that fails leaves the command to build cold, as it would with no seed. A command that
  /// builds in a worktree's own DerivedData waits, inside its deadline, for any other build there
  /// to end: `xcodebuild` fails a build whose build database another build holds.
  public func run(_ request: AreaCommandRequest) async -> AreaCommandOutcome {
    guard let copy = request.derivedDataSeed else { return await launch(request) }
    let destination = URL(filePath: copy.destination, directoryHint: .isDirectory)
    let lock = FileCountingLock(
      directory: destination.deletingLastPathComponent(),
      name: "\(destination.lastPathComponent).build-lock", capacity: 1)
    let clock = ContinuousClock()
    let started = clock.now
    let lease: LockLease
    do {
      lease = try await lock.acquire(timeout: request.deadline)
    } catch {
      return .timedOut(
        tail: "waited \(request.deadline.components.seconds) s for another build in "
          + "\(copy.destination) to end: \(error)")
    }
    defer { lease.release() }
    _ = await seeding.seed(copy)
    let left = request.deadline - (clock.now - started)
    return await launch(
      AreaCommandRequest(
        area: request.area, step: request.step, command: request.command,
        workingDirectory: request.workingDirectory, deadline: max(left, .milliseconds(1)),
        environment: request.environment, junitPath: request.junitPath,
        resultBundlePath: request.resultBundlePath, derivedDataSeed: copy))
  }

  private func launch(_ request: AreaCommandRequest) async -> AreaCommandOutcome {
    if let junitPath = request.junitPath { JUnitReportFiles.clear(at: junitPath) }
    // `xcodebuild` refuses a result bundle path that already exists.
    if let bundle = request.resultBundlePath { try? FileManager.default.removeItem(atPath: bundle) }
    let invocation = ProcessInvocation(
      executable: "/bin/sh", arguments: ["-c", "exec 2>&1\n" + request.command],
      environmentOverlay: request.environment.mapValues { $0 },
      workingDirectory: request.workingDirectory, timeout: request.deadline)
    let output: ProcessOutput
    do {
      output = try await processRunner.run(invocation)
    } catch {
      switch error {
      case .timedOut(_, _, let stdout, _):
        return AreaOutcomeReading.timedOut(output: stdout.text)
      case .launchFailed(_, let reason):
        // Status 127 is what `/bin/sh` reports for a command it can't start. A missing working
        // directory fails the launch with the same errno as a missing shell, so name it.
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(
          atPath: request.workingDirectory, isDirectory: &isDirectory) || !isDirectory.boolValue
        {
          return .failed(
            exit: 127, tail: "working directory \(request.workingDirectory) doesn't exist",
            junit: nil)
        }
        return .failed(exit: 127, tail: "could not start /bin/sh: \(reason)", junit: nil)
      case .cancelled:
        return .failed(exit: 130, tail: "cancelled before it finished", junit: nil)
      }
    }
    let end: AreaProcessEnd =
      switch output.status {
      case .exited(let status): .exited(status)
      case .signaled(let signal): .signaled(signal)
      }
    var junit = request.junitPath.flatMap(JUnitReportFiles.read(at:))
    if junit == nil, end != .exited(0), let bundle = request.resultBundlePath,
      let tests = try? await LiveXcresultReader(runner: processRunner).read(bundlePath: bundle)
    {
      junit = XcresultTestReport.junit(fromTests: tests.testResults)
    }
    return AreaOutcomeReading.outcome(end: end, output: output.stdout.text, junit: junit)
  }
}

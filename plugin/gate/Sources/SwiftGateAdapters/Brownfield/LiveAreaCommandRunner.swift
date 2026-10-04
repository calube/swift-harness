import Foundation
import SwiftGateDomain

/// Runs an area command through `/bin/sh -c` in the area root, with stderr folded into stdout so
/// the tail keeps the order the runner printed in.
public struct LiveAreaCommandRunner: AreaCommandRunning {
  private let processRunner: any ProcessRunner

  /// - Parameter processRunner: leads each command's own process group, so a timeout kills
  ///   every process the command started.
  public init(processRunner: any ProcessRunner = LiveProcessRunner()) {
    self.processRunner = processRunner
  }

  public func run(_ request: AreaCommandRequest) async -> AreaCommandOutcome {
    if let junitPath = request.junitPath { JUnitReportFiles.clear(at: junitPath) }
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
    let junit = request.junitPath.flatMap(JUnitReportFiles.read(at:))
    return AreaOutcomeReading.outcome(end: end, output: output.stdout.text, junit: junit)
  }
}

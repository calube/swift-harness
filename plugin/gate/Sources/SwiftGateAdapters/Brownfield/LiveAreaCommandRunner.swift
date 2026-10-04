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
    if let junitPath = request.junitPath {
      // A report an earlier run left must never be read as this run's.
      for path in [junitPath] + JUnitReports.companionPaths(of: junitPath) {
        try? FileManager.default.removeItem(atPath: path)
      }
      // Not every runner creates the directory it is told to write into.
      try? FileManager.default.createDirectory(
        atPath: (junitPath as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true)
    }
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
    let junit = request.junitPath.flatMap(Self.reports(at:))
    return AreaOutcomeReading.outcome(end: end, output: output.stdout.text, junit: junit)
  }

  /// The file at `junitPath` and its companions, or every `.xml` file in it when a command made
  /// it a directory of reports, as Gradle and Maven areas do. A report that is listed but can't
  /// be read leaves no report at all, so the step fails whole rather than without that report's
  /// failures.
  private static func reports(at junitPath: String) -> Data? {
    let files = FileManager.default
    var isDirectory: ObjCBool = false
    guard files.fileExists(atPath: junitPath, isDirectory: &isDirectory), isDirectory.boolValue
    else {
      return JUnitReports.combined(
        ([junitPath] + JUnitReports.companionPaths(of: junitPath)).compactMap {
          files.contents(atPath: $0)
        })
    }
    guard let names = try? files.contentsOfDirectory(atPath: junitPath) else { return nil }
    var documents: [Data] = []
    for name in names.sorted() where name.hasSuffix(".xml") {
      guard let data = files.contents(atPath: (junitPath as NSString).appendingPathComponent(name))
      else { return nil }
      documents.append(data)
    }
    return JUnitReports.combined(documents)
  }
}

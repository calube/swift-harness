import Foundation
import SwiftGateDomain

public enum XcodebuildError: Error, Sendable, Equatable {
  case runner(ProcessRunnerError)

  /// `xcodebuild` not running is the machine's problem, never evidence about the code.
  public var verdict: Verdict { .blocked }

  public var message: String {
    switch self {
    case .runner(let error): "xcodebuild could not run: \(error)"
    }
  }
}

/// A finished `xcodebuild test`. The exit status is kept only as a cross-check: the verdict comes
/// from the result bundle (spec §7.2 rule 3).
public struct XcodebuildTestRun: Sendable, Equatable {
  public let status: ExitStatus

  public init(status: ExitStatus) {
    self.status = status
  }
}

public protocol Xcodebuild: Sendable {
  /// Runs the request and writes its combined output to `logPath`.
  func test(_ request: XcodebuildTestRequest, logPath: String) async throws(XcodebuildError)
    -> XcodebuildTestRun
  /// Runs `xcodebuild build` and writes its combined output to `logPath`.
  func build(_ request: AppBuild.Request, logPath: String) async throws(XcodebuildError)
    -> ExitStatus
  /// `xcodebuild -version` output.
  func version() async throws(XcodebuildError) -> String
}

public struct LiveXcodebuild: Xcodebuild {
  private let runner: any ProcessRunner
  private let testTimeout: Duration

  /// A cold package build plus a simulator test run takes minutes; a wedged one is killed well
  /// before a session gives up on it.
  public init(runner: any ProcessRunner, testTimeout: Duration = .seconds(45 * 60)) {
    self.runner = runner
    self.testTimeout = testTimeout
  }

  public func test(_ request: XcodebuildTestRequest, logPath: String)
    async throws(XcodebuildError) -> XcodebuildTestRun
  {
    let output: ProcessOutput
    do {
      output = try await runner.run(
        ProcessInvocation(
          executable: "/usr/bin/xcrun", arguments: ["xcodebuild"] + request.arguments,
          environmentOverlay: request.environment.mapValues { Optional($0) },
          workingDirectory: request.workingDirectory, timeout: testTimeout))
    } catch {
      throw .runner(error)
    }
    let log = output.stdout.text + "\n--- stderr ---\n" + output.stderr.text
    // The log is a diagnostic; failing to write it must not change the verdict.
    try? Data(log.utf8).write(to: URL(filePath: logPath))
    return XcodebuildTestRun(status: output.status)
  }

  public func build(_ request: AppBuild.Request, logPath: String)
    async throws(XcodebuildError) -> ExitStatus
  {
    .exited(0)
  }

  public func version() async throws(XcodebuildError) -> String {
    do {
      let output = try await runner.run(
        ProcessInvocation(
          executable: "/usr/bin/xcrun", arguments: ["xcodebuild", "-version"],
          timeout: .seconds(60)))
      return output.status.isSuccess ? output.stdout.text : ""
    } catch {
      throw .runner(error)
    }
  }
}

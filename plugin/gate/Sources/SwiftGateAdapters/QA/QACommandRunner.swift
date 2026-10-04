import Darwin
import Foundation
import SwiftGateDomain

/// 1 acceptance or state check to run.
public struct QACheckRequest: Sendable, Equatable {
  public enum Program: Sendable, Equatable {
    /// A shell command line, run by `/bin/sh -c`.
    case command(String)
    /// A script file: run directly when it is executable, by `/bin/sh` otherwise.
    case script(path: String)
  }

  public let program: Program
  public let workingDirectory: String
  /// Set over the inherited environment, such as `QA_PORT`.
  public let environment: [String: String]
  public let timeout: Duration

  public init(
    program: Program, workingDirectory: String, environment: [String: String],
    timeout: Duration
  ) {
    self.program = program
    self.workingDirectory = workingDirectory
    self.environment = environment
    self.timeout = timeout
  }
}

/// How a check's process ended.
public enum QACheckExit: Sendable, Equatable {
  case exited(Int32)
  case signaled(Int32)
  case timedOut(Duration)
  /// The process never started; nothing about the check is known.
  case launchFailed(String)
}

public struct QACheckOutput: Sendable, Equatable {
  public let exit: QACheckExit
  public let stdout: String
  public let stderr: String
  public let elapsed: Duration

  public init(
    exit: QACheckExit, stdout: String = "", stderr: String = "", elapsed: Duration = .zero
  ) {
    self.exit = exit
    self.stdout = stdout
    self.stderr = stderr
    self.elapsed = elapsed
  }
}

public protocol QACheckRunning: Sendable {
  func run(_ request: QACheckRequest) async -> QACheckOutput
}

/// Why no port could be had for a row.
public struct QAPortError: Error, Sendable, Equatable, CustomStringConvertible {
  public let reason: String

  public init(reason: String) {
    self.reason = reason
  }

  public var description: String { reason }
}

/// A free TCP port for 1 row's `QA_PORT`.
public protocol QAPortAssigning: Sendable {
  func assignPort() throws(QAPortError) -> Int
}

/// Binds port 0 on the loopback address, reads the port the OS assigned, and closes the socket,
/// so the row's own server can bind it. No range is configured, so 2 runs never pick 1 port.
public struct LiveQAPorts: QAPortAssigning {
  public init() {}

  public func assignPort() throws(QAPortError) -> Int {
    throw QAPortError(reason: "not built")
  }
}

/// Runs a check through a ``ProcessRunner``, whose process group handling keeps a server the
/// check left behind from holding the output open.
public struct QACommandRunner: QACheckRunning {
  private let runner: any ProcessRunner

  public init(runner: any ProcessRunner) {
    self.runner = runner
  }

  public func run(_ request: QACheckRequest) async -> QACheckOutput {
    QACheckOutput(exit: .launchFailed("not built"))
  }
}

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
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw Self.failure("socket") }
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0 else { throw Self.failure("bind") }
    var assigned = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &assigned) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(descriptor, $0, &length)
      }
    }
    guard named == 0 else { throw Self.failure("getsockname") }
    let port = Int(UInt16(bigEndian: assigned.sin_port))
    guard port > 0 else { throw QAPortError(reason: "the OS assigned port 0") }
    return port
  }

  private static func failure(_ call: String) -> QAPortError {
    QAPortError(reason: "\(call) failed: \(String(cString: strerror(errno)))")
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
    let executable: String
    let arguments: [String]
    switch request.program {
    case .command(let line):
      executable = "/bin/sh"
      arguments = ["-c", line]
    case .script(let path) where FileManager.default.isExecutableFile(atPath: path):
      executable = path
      arguments = []
    case .script(let path):
      executable = "/bin/sh"
      arguments = [path]
    }
    let invocation = ProcessInvocation(
      executable: executable, arguments: arguments,
      environmentOverlay: request.environment.mapValues { $0 },
      workingDirectory: request.workingDirectory, timeout: request.timeout)
    do {
      let output = try await runner.run(invocation)
      let exit: QACheckExit =
        switch output.status {
        case .exited(let code): .exited(code)
        case .signaled(let signal): .signaled(signal)
        }
      return QACheckOutput(
        exit: exit, stdout: output.stdout.text, stderr: output.stderr.text,
        elapsed: output.elapsed)
    } catch {
      switch error {
      case .timedOut(_, let after, let stdout, let stderr):
        return QACheckOutput(
          exit: .timedOut(after), stdout: stdout.text, stderr: stderr.text, elapsed: after)
      case .launchFailed(_, let reason):
        return QACheckOutput(exit: .launchFailed(reason))
      case .cancelled:
        return QACheckOutput(exit: .launchFailed("cancelled before it finished"))
      }
    }
  }
}

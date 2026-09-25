import Foundation
import SwiftGateDomain

/// One external command. There is deliberately no shell-string form: `arguments` reach the child
/// verbatim as argv, so nothing in them is ever interpreted by a shell.
public struct ProcessInvocation: Sendable, Equatable {
  /// An absolute path, or a bare name resolved against the child's effective `PATH`.
  public var executable: String
  public var arguments: [String]
  /// Applied over the runner's base environment. A `nil` value removes the variable.
  public var environmentOverlay: [String: String?]
  public var workingDirectory: String?
  public var timeout: Duration
  public var maxCapturedBytesPerStream: Int

  public static let defaultMaxCapturedBytesPerStream = 32 * 1024 * 1024

  public init(
    executable: String,
    arguments: [String] = [],
    environmentOverlay: [String: String?] = [:],
    workingDirectory: String? = nil,
    timeout: Duration,
    maxCapturedBytesPerStream: Int = ProcessInvocation.defaultMaxCapturedBytesPerStream
  ) {
    precondition(timeout > .zero, "timeout must be positive")
    precondition(maxCapturedBytesPerStream >= 0, "capture cap must be non-negative")
    self.executable = executable
    self.arguments = arguments
    self.environmentOverlay = environmentOverlay
    self.workingDirectory = workingDirectory
    self.timeout = timeout
    self.maxCapturedBytesPerStream = maxCapturedBytesPerStream
  }
}

public enum ExitStatus: Sendable, Equatable {
  case exited(Int32)
  case signaled(Int32)

  public var isSuccess: Bool { self == .exited(0) }
}

/// Captured bytes from one output stream. `truncated` means the child wrote more than the cap;
/// the excess was read and discarded so the child never blocks on a full pipe.
public struct CapturedStream: Sendable, Equatable {
  public var bytes: Data
  public var truncated: Bool

  public init(bytes: Data = Data(), truncated: Bool = false) {
    self.bytes = bytes
    self.truncated = truncated
  }

  public var text: String { String(decoding: bytes, as: UTF8.self) }
}

/// A process that ran to exit. Any exit status, including nonzero or a signal, is a normal
/// result: interpreting it is the calling adapter's job.
public struct ProcessOutput: Sendable, Equatable {
  public var status: ExitStatus
  public var stdout: CapturedStream
  public var stderr: CapturedStream
  public var elapsed: Duration

  public init(
    status: ExitStatus, stdout: CapturedStream, stderr: CapturedStream, elapsed: Duration
  ) {
    self.status = status
    self.stdout = stdout
    self.stderr = stderr
    self.elapsed = elapsed
  }

  public init(
    status: ExitStatus, stdout: String = "", stderr: String = "", elapsed: Duration = .zero
  ) {
    self.init(
      status: status, stdout: CapturedStream(bytes: Data(stdout.utf8)),
      stderr: CapturedStream(bytes: Data(stderr.utf8)), elapsed: elapsed)
  }
}

/// The process produced no exit status to judge. Every case is an environment problem, never
/// evidence about the code under test.
public enum ProcessRunnerError: Error, Sendable, Equatable {
  case launchFailed(executable: String, reason: String)
  case timedOut(
    executable: String, after: Duration, stdout: CapturedStream, stderr: CapturedStream)
  case cancelled(executable: String)

  public var verdict: Verdict {
    switch self {
    case .launchFailed, .timedOut, .cancelled: .blocked
    }
  }
}

public protocol ProcessRunner: Sendable {
  func run(_ invocation: ProcessInvocation) async throws(ProcessRunnerError) -> ProcessOutput
}

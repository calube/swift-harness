import Darwin
import Foundation

/// A process to start and leave running after its parent exits.
public struct DetachedLaunch: Sendable, Equatable {
  public var executable: String
  public var arguments: [String]
  public var workingDirectory: String
  /// Receives the process's stdout and stderr, appended; stdin is `/dev/null`.
  public var logPath: String

  public init(executable: String, arguments: [String], workingDirectory: String, logPath: String) {
    self.executable = executable
    self.arguments = arguments
    self.workingDirectory = workingDirectory
    self.logPath = logPath
  }
}

public enum DetachedLaunchError: Error, Sendable, Equatable {
  case spawn(executable: String, errno: Int32)

  public var message: String {
    switch self {
    case .spawn(let executable, let code):
      "could not start \(executable): \(String(cString: strerror(code)))"
    }
  }
}

public protocol DetachedLaunching: Sendable {
  /// Starts the process and returns its PID without waiting for it.
  func launch(_ request: DetachedLaunch) throws(DetachedLaunchError) -> Int32
}

/// Starts a process in a session of its own, so the terminal or tool call that ran its parent can
/// end, and its process group be signalled, without taking the process with it.
public struct DetachedLauncher: DetachedLaunching {
  public init() {}

  public func launch(_ request: DetachedLaunch) throws(DetachedLaunchError) -> Int32 {
    throw .spawn(executable: request.executable, errno: ENOSYS)
  }
}

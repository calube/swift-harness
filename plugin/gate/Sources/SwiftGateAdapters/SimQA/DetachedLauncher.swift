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
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(
      &actions, 1, request.logPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    posix_spawn_file_actions_adddup2(&actions, 1, 2)
    posix_spawn_file_actions_addchdir_np(&actions, request.workingDirectory)

    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    // A fresh session detaches it from the caller's terminal and process group. Closing every
    // other descriptor keeps it from holding the caller's pipes open, which would make whoever
    // reads the caller's output wait for the holder too.
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

    let argv = ([request.executable] + request.arguments).map { strdup($0) } + [nil]
    defer { for pointer in argv { free(pointer) } }
    var pid: pid_t = 0
    let status = posix_spawn(&pid, request.executable, &actions, &attributes, argv, environ)
    guard status == 0 else { throw .spawn(executable: request.executable, errno: status) }
    return pid
  }
}

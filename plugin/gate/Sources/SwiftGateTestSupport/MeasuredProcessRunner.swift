import Darwin
import Foundation
import SwiftGateAdapters
import Synchronization

/// A real `ProcessRunner`, independent of `LiveProcessRunner`, that reaps each child it spawns
/// with `wait4(2)` and keeps a running total of every child's own CPU time.
///
/// `wait4`'s `rusage` out-parameter is that one child's exact resource usage — its own execution
/// plus any of its own children it waited for (so `git` shelling out further is still counted) —
/// never a process-wide counter (`getrusage(RUSAGE_CHILDREN)`) that some other, concurrently
/// running test's child could also add to. Give a hook-latency test a fresh instance per sample
/// and read ``totalChildCPUMilliseconds`` afterwards: that is exactly, and only, the CPU that
/// sample's own child processes used, no matter how busy the rest of the test binary is.
public final class MeasuredProcessRunner: ProcessRunner, Sendable {
  private let environment: [String: String]
  private let totalMicroseconds = Mutex<Int64>(0)

  public init(baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
    self.environment = baseEnvironment
  }

  /// The summed CPU time (user + system) of every child this instance has reaped so far.
  public var totalChildCPUMilliseconds: Int {
    Int(totalMicroseconds.withLock { $0 } / 1000)
  }

  public func run(_ invocation: ProcessInvocation) async throws(ProcessRunnerError)
    -> ProcessOutput
  {
    let resolved = Self.resolve(invocation.executable, environment: environment)
    let mergedEnvironment: [String: String] = {
      var merged = environment
      for (key, value) in invocation.environmentOverlay {
        if let value {
          merged[key] = value
        } else {
          merged.removeValue(forKey: key)
        }
      }
      return merged
    }()

    // A blocking spawn-and-wait, like `LiveProcessRunner`'s, runs on its own dedicated thread
    // rather than a cooperative-pool one, so one slow test's git call can't starve the pool
    // every other concurrently running test also needs.
    let outcome = await withCheckedContinuation {
      (continuation: CheckedContinuation<Outcome, Never>) in
      let thread = Thread {
        continuation.resume(
          returning: Self.spawnAndWait(
            executable: resolved, arguments: invocation.arguments,
            workingDirectory: invocation.workingDirectory, environment: mergedEnvironment))
      }
      thread.name = "swiftgate.measured-process"
      thread.start()
    }
    switch outcome {
    case .launchFailed(let reason):
      throw .launchFailed(executable: invocation.executable, reason: reason)
    case .finished(let output, let microseconds):
      totalMicroseconds.withLock { $0 += microseconds }
      return output
    }
  }

  private enum Outcome {
    case launchFailed(String)
    case finished(ProcessOutput, Int64)
  }

  private static func spawnAndWait(
    executable: String, arguments: [String], workingDirectory: String?,
    environment: [String: String]
  ) -> Outcome {
    var outPipe: [Int32] = [-1, -1]
    var errPipe: [Int32] = [-1, -1]
    guard outPipe.withUnsafeMutableBufferPointer({ pipe($0.baseAddress) }) == 0,
      errPipe.withUnsafeMutableBufferPointer({ pipe($0.baseAddress) }) == 0
    else {
      return .launchFailed("could not open a pipe: \(String(cString: strerror(errno)))")
    }

    var fileActions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fileActions)
    defer { posix_spawn_file_actions_destroy(&fileActions) }
    posix_spawn_file_actions_adddup2(&fileActions, outPipe[1], 1)
    posix_spawn_file_actions_adddup2(&fileActions, errPipe[1], 2)
    posix_spawn_file_actions_addclose(&fileActions, outPipe[0])
    posix_spawn_file_actions_addclose(&fileActions, errPipe[0])
    posix_spawn_file_actions_addclose(&fileActions, outPipe[1])
    posix_spawn_file_actions_addclose(&fileActions, errPipe[1])
    if let workingDirectory {
      posix_spawn_file_actions_addchdir_np(&fileActions, workingDirectory)
    }

    let argv = CStringVector([executable] + arguments)
    let envp = CStringVector(environment.map { "\($0.key)=\($0.value)" }.sorted())
    defer {
      argv.free()
      envp.free()
    }

    var pid: pid_t = 0
    let rc = posix_spawn(&pid, executable, &fileActions, nil, argv.pointers, envp.pointers)
    close(outPipe[1])
    close(errPipe[1])
    guard rc == 0 else {
      close(outPipe[0])
      close(errPipe[0])
      return .launchFailed(String(cString: strerror(rc)))
    }

    let stdoutData = readAll(outPipe[0])
    let stderrData = readAll(errPipe[0])
    close(outPipe[0])
    close(errPipe[0])

    var status: Int32 = 0
    var usage = rusage()
    while wait4(pid, &status, 0, &usage) == -1 && errno == EINTR {}
    let microseconds =
      Int64(usage.ru_utime.tv_sec) * 1_000_000 + Int64(usage.ru_utime.tv_usec)
      + Int64(usage.ru_stime.tv_sec) * 1_000_000 + Int64(usage.ru_stime.tv_usec)

    let exitStatus: ExitStatus =
      (status & 0x7f) == 0 ? .exited((status >> 8) & 0xff) : .signaled(status & 0x7f)
    let output = ProcessOutput(
      status: exitStatus, stdout: String(decoding: stdoutData, as: UTF8.self),
      stderr: String(decoding: stderrData, as: UTF8.self))
    return .finished(output, microseconds)
  }

  private static func readAll(_ descriptor: Int32) -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 8192)
    while true {
      let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
      if count <= 0 { break }
      data.append(contentsOf: buffer[0..<count])
    }
    return data
  }

  private static func resolve(_ executable: String, environment: [String: String]) -> String {
    guard !executable.contains("/") else { return executable }
    let searchPath = environment["PATH"] ?? "/usr/bin:/bin"
    for directory in searchPath.split(separator: ":") {
      let candidate = "\(directory)/\(executable)"
      if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return executable
  }
}

/// A `NULL`-terminated `char**` owning its own `strdup`'d strings, for `posix_spawn`.
private final class CStringVector {
  let pointers: [UnsafeMutablePointer<CChar>?]

  init(_ strings: [String]) {
    pointers = strings.map { strdup($0) } + [nil]
  }

  func free() {
    for pointer in pointers where pointer != nil { Darwin.free(pointer) }
  }
}

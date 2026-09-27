import Darwin
import Foundation
import Synchronization

/// Runs processes with `posix_spawn` rather than `Foundation.Process` because the child must lead
/// its own process group: on timeout or cancellation the whole group is signalled, so grandchildren
/// (compilers, test runners, simulators) cannot survive and keep the output pipes open forever.
///
/// Each run blocks one dedicated thread (not a cooperative-pool thread) for its lifetime.
public struct LiveProcessRunner: ProcessRunner {
  private let baseEnvironment: [String: String]
  private let terminationGracePeriod: Duration
  private let postExitDrainLimit: Duration
  private let now: @Sendable () -> ContinuousClock.Instant

  /// `/usr/bin/git` is an `xcrun` shim that exports these into every git hook. Inherited by
  /// `swift`/`xcodebuild`, `SDKROOT` points builds at the CommandLineTools SDK instead of the
  /// pinned Xcode's, and the changed build settings rebuild every package from scratch.
  static let droppedVariables: Set<String> = ["SDKROOT", "CPATH", "LIBRARY_PATH"]

  /// - Parameters:
  ///   - baseEnvironment: the environment every invocation's overlay is applied to, minus
  ///     ``droppedVariables``.
  ///   - terminationGracePeriod: time between SIGTERM and SIGKILL to the process group.
  ///   - postExitDrainLimit: how long to keep reading after the child exits, in case a surviving
  ///     descendant still holds the pipes open.
  ///   - now: the clock the timeout, grace period and drain limit are measured on.
  public init(
    baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
    terminationGracePeriod: Duration = .seconds(2),
    postExitDrainLimit: Duration = .seconds(2),
    now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
  ) {
    self.baseEnvironment = baseEnvironment.filter { !Self.droppedVariables.contains($0.key) }
    self.terminationGracePeriod = terminationGracePeriod
    self.postExitDrainLimit = postExitDrainLimit
    self.now = now
  }

  public func run(_ invocation: ProcessInvocation) async throws(ProcessRunnerError)
    -> ProcessOutput
  {
    let environment = effectiveEnvironment(overlay: invocation.environmentOverlay)
    let path = try resolveExecutable(invocation.executable, environment: environment)
    let spawn = SpawnRequest(
      path: path, invocation: invocation, environment: environment,
      terminationGracePeriod: terminationGracePeriod, postExitDrainLimit: postExitDrainLimit,
      now: now)
    let cancellation = CancellationSignal()

    let result = await withTaskCancellationHandler {
      await withCheckedContinuation {
        (continuation: CheckedContinuation<Result<ProcessOutput, ProcessRunnerError>, Never>) in
        let thread = Thread {
          continuation.resume(returning: spawn.execute(cancellation: cancellation))
        }
        thread.name = "swiftgate.process"
        thread.start()
      }
    } onCancel: {
      cancellation.cancel()
    }
    return try result.get()
  }

  private func effectiveEnvironment(overlay: [String: String?]) -> [String: String] {
    var environment = baseEnvironment
    for (key, value) in overlay {
      if let value {
        environment[key] = value
      } else {
        environment.removeValue(forKey: key)
      }
    }
    return environment
  }

  private func resolveExecutable(_ executable: String, environment: [String: String])
    throws(ProcessRunnerError) -> String
  {
    guard !executable.isEmpty else {
      throw .launchFailed(executable: executable, reason: "empty executable")
    }
    if executable.contains("/") { return executable }
    let searchPath = environment["PATH"] ?? ""
    for directory in searchPath.split(separator: ":") where !directory.isEmpty {
      let candidate = "\(directory)/\(executable)"
      if isExecutableFile(candidate) { return candidate }
    }
    throw .launchFailed(executable: executable, reason: "not found on PATH \(searchPath)")
  }

  private func isExecutableFile(_ path: String) -> Bool {
    var info = stat()
    guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return false }
    return access(path, X_OK) == 0
  }
}

/// Every child leads its own process group, so a signal to this process's group (Ctrl-C, or a
/// harness stopping a run) never reaches the children. Without this, a killed run leaves its
/// builds and test runners behind, and they pile up across runs until the machine wedges.
/// Signals are process-wide, so this is too; it arms itself before the first child starts.
private let liveChildGroups = ChildProcessGroups()

/// The write end of the pipe the signal handler reports to; `-1` until the handler is installed.
private let signalPipeWriteEnd = Atomic<Int32>(-1)

private final class ChildProcessGroups: Sendable {
  static let forwarded: [Int32] = [SIGTERM, SIGINT, SIGHUP]

  private let groups = Mutex<Set<pid_t>>([])

  init() {
    var fds: [Int32] = [-1, -1]
    guard pipe(&fds) == 0 else { return }
    for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
    signalPipeWriteEnd.store(fds[1], ordering: .releasing)
    let reader = fds[0]
    // A signal handler may only make async-signal-safe calls, so it hands the signal to this
    // thread, which may take the lock a spawn in progress holds.
    Thread { [self] in
      var number: Int32 = 0
      while read(reader, &number, MemoryLayout<Int32>.size) == MemoryLayout<Int32>.size {
        terminate(on: number)
      }
    }.start()
    for number in Self.forwarded {
      var action = sigaction()
      action.__sigaction_u.__sa_handler = { number in
        var number = number
        _ = write(
          signalPipeWriteEnd.load(ordering: .acquiring), &number, MemoryLayout<Int32>.size)
      }
      action.sa_flags = SA_RESTART
      sigaction(number, &action, nil)
    }
  }

  /// Signals every child group, waiting out a spawn in progress so a child started this instant
  /// is signalled too, then ends this process as `number` would have.
  private func terminate(on number: Int32) {
    for group in groups.withLock({ $0 }) { kill(-group, SIGTERM) }
    signal(number, SIG_DFL)
    kill(getpid(), number)
  }

  /// Runs `spawn` and records the child it started as one atomic step with respect to the
  /// signal handler.
  func spawning<Failure: Error>(_ spawn: () -> Result<pid_t, Failure>) -> Result<pid_t, Failure> {
    groups.withLock { groups in
      let spawned = spawn()
      if case .success(let pid) = spawned { groups.insert(pid) }
      return spawned
    }
  }

  func remove(_ group: pid_t) { _ = groups.withLock { $0.remove(group) } }
}

private final class CancellationSignal: Sendable {
  private let flag = Atomic<Bool>(false)

  func cancel() { flag.store(true, ordering: .releasing) }
  var isCancelled: Bool { flag.load(ordering: .acquiring) }
}

private struct SpawnRequest: Sendable {
  let path: String
  let invocation: ProcessInvocation
  let environment: [String: String]
  let terminationGracePeriod: Duration
  let postExitDrainLimit: Duration
  let now: @Sendable () -> ContinuousClock.Instant

  private enum Termination {
    case none
    case timedOut
    case cancelled
  }

  func execute(cancellation: CancellationSignal) -> Result<ProcessOutput, ProcessRunnerError> {
    let executable = invocation.executable
    if cancellation.isCancelled { return .failure(.cancelled(executable: executable)) }

    let stdoutPipe: Pipe
    let stderrPipe: Pipe
    do {
      stdoutPipe = try Pipe.make()
      stderrPipe = try Pipe.make()
    } catch {
      return .failure(.launchFailed(executable: executable, reason: error.reason))
    }

    let stdin: Int32?
    do {
      stdin = try invocation.standardInput.map(Self.unlinkedFile(holding:))
    } catch {
      stdoutPipe.closeAll()
      stderrPipe.closeAll()
      return .failure(.launchFailed(executable: executable, reason: error.reason))
    }

    let start = now()
    let pid: pid_t
    let spawned = liveChildGroups.spawning {
      spawn(stdin: stdin, stdout: stdoutPipe.write, stderr: stderrPipe.write)
    }
    if let stdin { close(stdin) }
    switch spawned {
    case .success(let child): pid = child
    case .failure(let error):
      stdoutPipe.closeAll()
      stderrPipe.closeAll()
      return .failure(.launchFailed(executable: executable, reason: error.reason))
    }
    close(stdoutPipe.write)
    close(stderrPipe.write)

    var stdoutReader = StreamReader(fd: stdoutPipe.read, cap: invocation.maxCapturedBytesPerStream)
    var stderrReader = StreamReader(fd: stderrPipe.read, cap: invocation.maxCapturedBytesPerStream)
    defer {
      stdoutReader.close()
      stderrReader.close()
    }

    let deadline = start.advanced(by: invocation.timeout)
    var status: ExitStatus?
    var exitedAt: ContinuousClock.Instant?
    var termination = Termination.none
    var terminateSentAt: ContinuousClock.Instant?
    var killSent = false

    while true {
      let now = self.now()
      if termination == .none {
        if cancellation.isCancelled {
          termination = .cancelled
        } else if status == nil, now >= deadline {
          termination = .timedOut
        }
        if termination != .none {
          kill(-pid, SIGTERM)
          terminateSentAt = now
        }
      } else if !killSent, let sent = terminateSentAt, now - sent >= terminationGracePeriod {
        kill(-pid, SIGKILL)
        killSent = true
      }

      if status == nil, let reaped = Self.reap(pid) {
        status = reaped
        exitedAt = now
      }
      if let exitedAt {
        let drained = !stdoutReader.isOpen && !stderrReader.isOpen
        let drainExpired = now - exitedAt >= postExitDrainLimit
        let waitingOnKill = termination != .none && !killSent && !drained
        if drained || (drainExpired && !waitingOnKill) { break }
      }

      Self.pollReadable(&stdoutReader, &stderrReader, timeoutMilliseconds: 20)
    }

    liveChildGroups.remove(pid)  // swiftgate:equivalent-mutant — observable only on pid reuse
    let elapsed = now() - start
    switch termination {
    case .cancelled:
      return .failure(.cancelled(executable: executable))
    case .timedOut:
      return .failure(
        .timedOut(
          executable: executable, after: invocation.timeout, stdout: stdoutReader.captured,
          stderr: stderrReader.captured))
    case .none:
      // `status` is always set here: the loop only exits after the child is reaped.
      guard let status else {
        return .failure(.launchFailed(executable: executable, reason: "child was never reaped"))
      }
      return .success(
        ProcessOutput(
          status: status, stdout: stdoutReader.captured, stderr: stderrReader.captured,
          elapsed: elapsed))
    }
  }

  /// Standard input is a file rather than a pipe: the child reads it at its own pace, so a child
  /// that writes a lot before reading cannot deadlock against a parent blocked on a full pipe.
  private static func unlinkedFile(holding data: Data) throws(SystemError) -> Int32 {
    var template = Array((NSTemporaryDirectory() + "swiftgate-stdin.XXXXXX").utf8CString)
    let fd = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress) }
    guard fd >= 0 else { throw SystemError(code: errno) }
    // mkstemp filled in the X's; the trailing NUL is not part of the path.
    unlink(String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self))
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    var offset = 0
    while offset < data.count {
      let written = data.withUnsafeBytes { buffer in
        Darwin.write(fd, buffer.baseAddress?.advanced(by: offset), data.count - offset)
      }
      if written < 0 {
        if errno == EINTR { continue }
        let code = errno
        close(fd)
        throw SystemError(code: code)
      }
      offset += written
    }
    lseek(fd, 0, SEEK_SET)
    return fd
  }

  private func spawn(stdin: Int32?, stdout: Int32, stderr: Int32) -> Result<pid_t, SystemError> {
    var fileActions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fileActions)
    defer { posix_spawn_file_actions_destroy(&fileActions) }
    if let stdin {
      posix_spawn_file_actions_adddup2(&fileActions, stdin, 0)
    } else {
      posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
    }
    posix_spawn_file_actions_adddup2(&fileActions, stdout, 1)
    posix_spawn_file_actions_adddup2(&fileActions, stderr, 2)
    if let directory = invocation.workingDirectory {
      posix_spawn_file_actions_addchdir_np(&fileActions, directory)
    }

    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    // CLOEXEC_DEFAULT keeps unrelated descriptors (other runs' pipes) out of the child.
    let flags =
      POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
      | POSIX_SPAWN_CLOEXEC_DEFAULT
    posix_spawnattr_setflags(&attributes, Int16(flags))
    posix_spawnattr_setpgroup(&attributes, 0)
    var defaultSignals = sigset_t()
    sigfillset(&defaultSignals)
    posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
    var noMask = sigset_t()
    sigemptyset(&noMask)
    posix_spawnattr_setsigmask(&attributes, &noMask)

    let argv = CStringArray([path] + invocation.arguments)
    let envp = CStringArray(environment.map { "\($0.key)=\($0.value)" }.sorted())
    defer {
      argv.free()
      envp.free()
    }

    var pid: pid_t = 0
    let rc = posix_spawn(&pid, path, &fileActions, &attributes, argv.pointers, envp.pointers)
    return rc == 0 ? .success(pid) : .failure(SystemError(code: rc))
  }

  private static func reap(_ pid: pid_t) -> ExitStatus? {
    var raw: Int32 = 0
    while true {
      let result = waitpid(pid, &raw, WNOHANG)
      if result == pid { break }
      if result == -1, errno == EINTR { continue }
      return nil
    }
    let signal = raw & 0x7f
    return signal == 0 ? .exited((raw >> 8) & 0xff) : .signaled(signal)
  }

  private static func pollReadable(
    _ first: inout StreamReader, _ second: inout StreamReader, timeoutMilliseconds: Int32
  ) {
    var fds: [pollfd] = []
    if first.isOpen { fds.append(pollfd(fd: first.fd, events: Int16(POLLIN), revents: 0)) }
    if second.isOpen { fds.append(pollfd(fd: second.fd, events: Int16(POLLIN), revents: 0)) }
    guard !fds.isEmpty else {
      usleep(UInt32(timeoutMilliseconds) * 1000)
      return
    }
    guard poll(&fds, nfds_t(fds.count), timeoutMilliseconds) > 0 else { return }
    for entry in fds where entry.revents != 0 {
      if entry.fd == first.fd { first.drainAvailable() } else { second.drainAvailable() }
    }
  }
}

private struct SystemError: Error {
  let code: Int32
  var reason: String { String(cString: strerror(code)) }
}

private struct Pipe {
  let read: Int32
  let write: Int32

  static func make() throws(SystemError) -> Pipe {
    var fds: [Int32] = [0, 0]
    guard pipe(&fds) == 0 else { throw SystemError(code: errno) }
    for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
    _ = fcntl(fds[0], F_SETFL, fcntl(fds[0], F_GETFL) | O_NONBLOCK)
    return Pipe(read: fds[0], write: fds[1])
  }

  func closeAll() {
    close(read)
    close(write)
  }
}

private struct StreamReader {
  let fd: Int32
  let cap: Int
  private(set) var isOpen = true
  private(set) var captured = CapturedStream()

  init(fd: Int32, cap: Int) {
    self.fd = fd
    self.cap = cap
  }

  mutating func drainAvailable() {
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while isOpen {
      let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
      if count > 0 {
        append(buffer[0..<count])
      } else if count == 0 {
        close()
      } else if errno == EINTR {
        continue
      } else {
        if errno != EAGAIN { close() }
        return
      }
    }
  }

  mutating func close() {
    guard isOpen else { return }
    isOpen = false
    Darwin.close(fd)
  }

  private mutating func append(_ bytes: ArraySlice<UInt8>) {
    let room = max(0, cap - captured.bytes.count)
    if bytes.count > room { captured.truncated = true }
    captured.bytes.append(contentsOf: bytes.prefix(room))
  }
}

private struct CStringArray {
  let pointers: [UnsafeMutablePointer<CChar>?]

  init(_ strings: [String]) {
    pointers = strings.map { strdup($0) } + [nil]
  }

  func free() {
    for pointer in pointers { Darwin.free(pointer) }
  }
}

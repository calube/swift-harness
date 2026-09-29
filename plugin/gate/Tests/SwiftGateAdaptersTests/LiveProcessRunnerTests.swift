import Darwin
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import Synchronization
import Testing

@Suite("LiveProcessRunner")
struct LiveProcessRunnerTests {
  let runner = LiveProcessRunner(baseEnvironment: ["PATH": "/usr/bin:/bin"])

  @Test("nonzero exit returns output, not an error — catches a failing tool being classed BLOCKED")
  func nonzeroExitIsOutput() async throws {
    let output = try await runner.run(
      ProcessInvocation(
        executable: "/bin/sh", arguments: ["-c", "printf out; printf err >&2; exit 3"],
        timeout: .seconds(10)))
    #expect(output.status == .exited(3))
    #expect(output.stdout.text == "out")
    #expect(output.stderr.text == "err")
    #expect(!output.status.isSuccess)
  }

  @Test(
    "standard input reaches the child and ends at EOF — catches batch readers hanging on /dev/null or an open pipe"
  )
  func standardInputReachesChild() async throws {
    let lines = (1...5000).map { "line \($0)" }.joined(separator: "\n") + "\n"
    let output = try await runner.run(
      ProcessInvocation(
        executable: "/usr/bin/wc", arguments: ["-l"], standardInput: Data(lines.utf8),
        timeout: .seconds(10)))
    #expect(output.stdout.text.trimmingCharacters(in: .whitespaces) == "5000\n")
  }

  @Test("arguments are passed verbatim, never shell-interpreted — catches command injection")
  func argumentsAreNotShellInterpreted() async throws {
    let hostile = "$(echo pwned); `id` | cat > x"
    let output = try await runner.run(
      ProcessInvocation(executable: "/bin/echo", arguments: [hostile], timeout: .seconds(10)))
    #expect(output.stdout.text == hostile + "\n")
  }

  @Test("missing executable is a launch failure — catches a missing tool reported as RED")
  func missingExecutableIsLaunchFailure() async {
    await #expect {
      _ = try await runner.run(
        ProcessInvocation(executable: "/nonexistent/tool", timeout: .seconds(10)))
    } throws: { error in
      guard case .launchFailed(let executable, _) = error as? ProcessRunnerError else {
        return false
      }
      return executable == "/nonexistent/tool"
    }
  }

  @Test("bare names resolve on the effective PATH, not the parent's — catches env overlay bypass")
  func bareNameUsesEffectivePath() async throws {
    let found = try await runner.run(ProcessInvocation(executable: "env", timeout: .seconds(10)))
    #expect(found.status == .exited(0))

    let restricted = LiveProcessRunner(baseEnvironment: ["PATH": "/nonexistent"])
    await #expect {
      _ = try await restricted.run(ProcessInvocation(executable: "env", timeout: .seconds(10)))
    } throws: { error in
      if case .launchFailed = error as? ProcessRunnerError { return true }
      return false
    }
  }

  @Test(
    "env overlay replaces and removes parent values — catches SNAPSHOT_TESTING_RECORD leaking in")
  func environmentOverlay() async throws {
    let runner = LiveProcessRunner(baseEnvironment: [
      "PATH": "/usr/bin:/bin", "SNAPSHOT_TESTING_RECORD": "all", "DROP_ME": "x", "KEEP": "1",
    ])
    let output = try await runner.run(
      ProcessInvocation(
        executable: "/usr/bin/env",
        environmentOverlay: ["SNAPSHOT_TESTING_RECORD": "never", "DROP_ME": nil],
        timeout: .seconds(10)))
    let lines = Set(output.stdout.text.split(separator: "\n").map(String.init))
    #expect(lines.contains("SNAPSHOT_TESTING_RECORD=never"))
    #expect(!lines.contains("SNAPSHOT_TESTING_RECORD=all"))
    #expect(!lines.contains { $0.hasPrefix("DROP_ME=") })
    #expect(lines.contains("KEEP=1"))
  }

  @Test(
    "the SDK variables Apple's git shim exports into git hooks never reach a child — catches the pre-push gate rebuilding every package against the CommandLineTools SDK"
  )
  func gitShimSDKVariablesDropped() async throws {
    let runner = LiveProcessRunner(baseEnvironment: [
      "PATH": "/usr/bin:/bin", "SDKROOT": "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk",
      "CPATH": "/usr/local/include", "LIBRARY_PATH": "/usr/local/lib", "KEEP": "1",
    ])
    let output = try await runner.run(
      ProcessInvocation(executable: "/usr/bin/env", timeout: .seconds(10)))
    let names = Set(
      output.stdout.text.split(separator: "\n").map { String($0.prefix { $0 != "=" }) })
    #expect(names.isDisjoint(with: ["SDKROOT", "CPATH", "LIBRARY_PATH"]))
    #expect(names.contains("KEEP"))
  }

  @Test(
    "git found at the /usr/bin xcrun shim runs the developer dir's own git, with no xcrun lookup — catches a concurrent swift launch turning swiftgate's git into swift",
    .enabled(
      if: FileManager.default.isExecutableFile(atPath: "/usr/bin/git"),
      "this machine has no /usr/bin/git shim"))
  func gitSkipsTheXcrunShim() async throws {
    // The shim prints its lookup under `xcrun_verbose`; git itself ignores the variable.
    let output = try await runner.run(
      ProcessInvocation(
        executable: "git", arguments: ["--version"], environmentOverlay: ["xcrun_verbose": "1"],
        timeout: .seconds(30)))

    #expect(output.status.isSuccess, "\(output.stderr.text)")
    #expect(output.stdout.text.hasPrefix("git version"))
    #expect(!output.stderr.text.contains("xcrun_db"), "\(output.stderr.text)")
  }

  @Test(
    "a DEVELOPER_DIR in the invocation's environment picks the git that runs — catches the resolution ignoring the Xcode a caller selects"
  )
  func gitFollowsTheInvocationDeveloperDirectory() async throws {
    let developer = FileManager.default.temporaryDirectory.appending(
      path: "developer-dir-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: developer) }
    let tools = developer.appending(path: "usr/bin", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
    try Data("#!/bin/sh\necho selected git \"$@\"\n".utf8).write(to: tools.appending(path: "git"))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: tools.appending(path: "git").path)

    let output = try await runner.run(
      ProcessInvocation(
        executable: "git", arguments: ["--version"],
        environmentOverlay: ["DEVELOPER_DIR": developer.path], timeout: .seconds(30)))

    #expect(output.stdout.text == "selected git --version\n", "\(output.stderr.text)")
  }

  @Test("working directory is applied — catches tools running against the wrong package")
  func workingDirectory() async throws {
    let output = try await runner.run(
      ProcessInvocation(executable: "/bin/pwd", workingDirectory: "/usr", timeout: .seconds(10)))
    #expect(output.stdout.text == "/usr\n")
  }

  @Test("a nonexistent working directory is a launch failure — catches running in the cwd instead")
  func missingWorkingDirectory() async {
    await #expect {
      _ = try await runner.run(
        ProcessInvocation(
          executable: "/bin/pwd", workingDirectory: "/nonexistent-dir", timeout: .seconds(10)))
    } throws: { error in
      if case .launchFailed = error as? ProcessRunnerError { return true }
      return false
    }
  }

  /// How long every process in a ``tree(_:)`` sleeps. A run whose whole tree is gone in under
  /// half of it was killed rather than left to finish, and a process the runner fails to kill
  /// still ends the test, on a failed assertion, once it runs out.
  private static let treeLifetime = 120
  private static let killedWell = Duration.seconds(treeLifetime / 2)

  static let hasPython = FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")

  /// One process the runner's direct child forks before it reports ready.
  private struct Grandchild {
    /// Moves into a process group of its own, as `swift test`'s `xctest` /
    /// `swiftpm-testing-helper` does, out of reach of a signal to the child's group.
    var ownGroup = false
    var ignoresTerm = false
  }

  /// A direct child (python, since the shell can't `setpgid`) that forks `grandchildren`, prints
  /// `started` when `started` is set, then sleeps. Every process in the tree, the child included,
  /// opens `$READY` for writing, writes one line (`held <pid>` for a grandchild, `ready` for the
  /// child) and holds it open for life, so the pipe reaches end-of-file only once the whole tree
  /// is gone.
  private static func tree(_ grandchildren: [Grandchild], started: Bool = false) -> [String] {
    let specs = grandchildren.map {
      "(\($0.ownGroup ? "True" : "False"), \($0.ignoresTerm ? "True" : "False"))"
    }
    let script = """
      import os, signal, sys, time
      ready = os.environ["READY"]
      for own_group, ignores_term in [\(specs.joined(separator: ", "))]:
          if os.fork() == 0:
              if own_group:
                  os.setpgid(0, 0)
              if ignores_term:
                  signal.signal(signal.SIGTERM, signal.SIG_IGN)
              fd = os.open(ready, os.O_WRONLY)
              os.write(fd, ("held %d\\n" % os.getpid()).encode())
              time.sleep(\(treeLifetime))
              os._exit(0)
      if \(started ? "True" : "False"):
          print("started", flush=True)
      fd = os.open(ready, os.O_WRONLY)
      os.write(fd, b"ready\\n")
      time.sleep(\(treeLifetime))
      """
    return ["-c", script]
  }

  /// Reads one line per process in the tree, so nothing is signalled before every process holds
  /// the pipe, and returns the grandchildren's pids for cleanup.
  private static func awaitTree(
    _ lines: inout AsyncStream<String>.Iterator, grandchildren: Int
  ) async throws -> [pid_t] {
    var pids: [pid_t] = []
    var sawReady = false
    for _ in 0...grandchildren {
      let line = try #require(await lines.next())
      if line == "ready" {
        sawReady = true
      } else {
        pids.append(try #require(pid_t(line.dropFirst("held ".count))))
      }
    }
    #expect(sawReady)
    #expect(pids.count == grandchildren)
    return pids
  }

  @Test(
    "timeout kills the child and every process it started, even one in a process group of its own, and throws a BLOCKED error — catches a hung tool wedging the gate or an orphaned xctest spinning after a mutate timeout",
    .enabled(if: hasPython, "/usr/bin/python3 is missing"))
  func timeoutKillsChild() async throws {
    let held = try HeldPipe()
    defer { held.remove() }
    var lines = held.lines().makeAsyncIterator()
    let clock = ShiftableClock()
    let runner = LiveProcessRunner(baseEnvironment: ["PATH": "/usr/bin:/bin"], now: clock.now)
    let timeout = Duration.seconds(3600)
    let start = ContinuousClock.now
    let run = Task {
      await Self.outcome(
        runner,
        ProcessInvocation(
          executable: "/usr/bin/python3",
          arguments: Self.tree([Grandchild(ownGroup: true)], started: true),
          environmentOverlay: ["READY": held.path], timeout: timeout))
    }
    let grandchildren = try await Self.awaitTree(&lines, grandchildren: 1)
    defer { for pid in grandchildren { kill(pid, SIGKILL) } }
    clock.advance(by: timeout)

    let result = await run.value
    #expect(await lines.next() == nil, "a process in the child's tree outlived the timeout")
    #expect(ContinuousClock.now - start < Self.killedWell)
    guard case .failure(let error) = result,
      case .timedOut(_, let after, let stdout, _) = error
    else {
      Issue.record("expected timedOut, got \(result)")
      return
    }
    #expect(after == timeout)
    #expect(stdout.text == "started\n")
    #expect(error.verdict == .blocked)
  }

  @Test(
    "timeout's SIGKILL reaches grandchildren that ignore SIGTERM and hold the pipes, in the child's group or their own, after the child itself has died — catches a hang, or a leaked process, after killing only the child",
    .enabled(if: hasPython, "/usr/bin/python3 is missing"))
  func timeoutKillsProcessGroup() async throws {
    let held = try HeldPipe()
    defer { held.remove() }
    var lines = held.lines().makeAsyncIterator()
    let clock = ShiftableClock()
    let patient = LiveProcessRunner(
      baseEnvironment: ["PATH": "/usr/bin:/bin"], terminationGracePeriod: .seconds(1),
      postExitDrainLimit: .seconds(3600), now: clock.now)
    let timeout = Duration.seconds(3600)
    let start = ContinuousClock.now
    let stubborn = [
      Grandchild(ownGroup: false, ignoresTerm: true), Grandchild(ownGroup: true, ignoresTerm: true),
    ]
    let run = Task {
      await Self.outcome(
        patient,
        ProcessInvocation(
          executable: "/usr/bin/python3", arguments: Self.tree(stubborn),
          environmentOverlay: ["READY": held.path], timeout: timeout))
    }
    let grandchildren = try await Self.awaitTree(&lines, grandchildren: stubborn.count)
    defer { for pid in grandchildren { kill(pid, SIGKILL) } }
    clock.advance(by: timeout)

    let result = await run.value
    #expect(await lines.next() == nil, "a grandchild outlived the timeout's SIGKILL")
    #expect(ContinuousClock.now - start < Self.killedWell)
    guard case .failure(.timedOut) = result else {
      Issue.record("expected timedOut, got \(result)")
      return
    }
  }

  @Test(
    "task cancellation kills the child and every process it started, even one in a process group of its own — catches orphaned tools after a hook is interrupted",
    .enabled(if: hasPython, "/usr/bin/python3 is missing"))
  func cancellationKillsChild() async throws {
    let held = try HeldPipe()
    defer { held.remove() }
    var lines = held.lines().makeAsyncIterator()
    let start = ContinuousClock.now
    let task = Task {
      try await runner.run(
        ProcessInvocation(
          executable: "/usr/bin/python3", arguments: Self.tree([Grandchild(ownGroup: true)]),
          environmentOverlay: ["READY": held.path], timeout: .seconds(3600)))
    }
    let grandchildren = try await Self.awaitTree(&lines, grandchildren: 1)
    defer { for pid in grandchildren { kill(pid, SIGKILL) } }
    task.cancel()

    let result = await task.result
    #expect(await lines.next() == nil, "a process in the child's tree outlived the cancellation")
    #expect(ContinuousClock.now - start < Self.killedWell)
    guard case .failure(let error) = result, case .cancelled = error as? ProcessRunnerError else {
      Issue.record("expected cancelled, got \(result)")
      return
    }
  }

  private static func outcome(_ runner: LiveProcessRunner, _ invocation: ProcessInvocation) async
    -> Result<ProcessOutput, ProcessRunnerError>
  {
    do {
      return .success(try await runner.run(invocation))
    } catch {
      return .failure(error)
    }
  }

  @Test("output beyond the cap is truncated but drained — catches OOM or a child blocked on a pipe")
  func outputCap() async throws {
    let output = try await runner.run(
      ProcessInvocation(
        executable: "/bin/sh", arguments: ["-c", "head -c 200000 /dev/zero"],
        timeout: .seconds(10), maxCapturedBytesPerStream: 1000))
    #expect(output.status == .exited(0))
    #expect(output.stdout.bytes.count == 1000)
    #expect(output.stdout.truncated)
    #expect(!output.stderr.truncated)
  }

  @Test("a signal-killed child reports the signal — catches a crash reported as a clean exit")
  func signaledChild() async throws {
    let output = try await runner.run(
      ProcessInvocation(
        executable: "/bin/sh", arguments: ["-c", "kill -9 $$"], timeout: .seconds(10))
    )
    #expect(output.status == .signaled(9))
    #expect(!output.status.isSuccess)
  }
}

/// A clock that runs with the real one until a test moves it forward, so a timeout fires exactly
/// when the test says the child is ready, never because the machine was slow. Kept in this file
/// (not test support) so `prove` reverting production source can never make a test that uses it
/// stop compiling: the merge base doesn't need to have known about it.
private final class ShiftableClock: Sendable {
  private let offsetNanoseconds = Atomic<Int64>(0)

  var now: @Sendable () -> ContinuousClock.Instant {
    { [self] in
      ContinuousClock.now.advanced(by: .nanoseconds(offsetNanoseconds.load(ordering: .acquiring)))
    }
  }

  func advance(by duration: Duration) {
    let (seconds, attoseconds) = duration.components
    let nanoseconds = seconds * 1_000_000_000 + attoseconds / 1_000_000_000
    offsetNanoseconds.add(nanoseconds, ordering: .releasing)
  }
}

/// A named pipe every process in a test's tree writes one line to once it is running and then
/// holds open for life, so a test can move a ``ShiftableClock`` past a timeout only once there is
/// something to time out, and can tell afterwards whether any of the tree survived. Kept in this
/// file for the same reason as ``ShiftableClock``.
private struct HeldPipe {
  let path: String
  private let directory: URL

  init() throws {
    directory = FileManager.default.temporaryDirectory.appending(
      path: "swiftgate-held-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    path = directory.appending(path: "held").path
    guard mkfifo(path, 0o600) == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
  }

  func remove() { try? FileManager.default.removeItem(at: directory) }

  /// The lines written, finishing once every writer has closed the pipe: for a tree that holds it
  /// for life, once the whole tree is gone. Reads on a dedicated thread: opening the pipe for
  /// reading blocks until a writer opens it, so this can't run on a cooperative-pool thread.
  func lines() -> AsyncStream<String> {
    AsyncStream { continuation in
      Thread { [path] in
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else {
          continuation.finish()
          return
        }
        defer { close(fd) }
        var pending: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 256)
        while true {
          let count = read(fd, &buffer, buffer.count)
          if count < 0, errno == EINTR { continue }
          if count <= 0 { break }
          pending += buffer[0..<count]
          while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            continuation.yield(String(decoding: pending[..<newline], as: UTF8.self))
            pending.removeSubrange(...newline)
          }
        }
        continuation.finish()
      }.start()
    }
  }
}

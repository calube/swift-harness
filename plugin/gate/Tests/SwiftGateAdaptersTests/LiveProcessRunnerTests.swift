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

  /// The child's own sleep. A run that returns in under half of it killed the child rather than
  /// waiting for it, with minutes of headroom however loaded the machine is.
  private static let childLifetime = 600
  private static let killedWell = Duration.seconds(childLifetime / 2)

  @Test("timeout kills the child and throws a BLOCKED error — catches a hung tool wedging the gate")
  func timeoutKillsChild() async throws {
    let ready = try ReadyPipe()
    defer { ready.remove() }
    let clock = ShiftableClock()
    let runner = LiveProcessRunner(baseEnvironment: ["PATH": "/usr/bin:/bin"], now: clock.now)
    let timeout = Duration.seconds(3600)
    let start = ContinuousClock.now
    let run = Task {
      await Self.outcome(
        runner,
        ProcessInvocation(
          executable: "/bin/sh",
          arguments: [
            "-c", "echo started; echo ready > \"$READY\"; exec sleep \(Self.childLifetime)",
          ],
          environmentOverlay: ["READY": ready.path], timeout: timeout))
    }
    #expect(await ready.firstLine() == "ready")
    clock.advance(by: timeout)

    let result = await run.value
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
    "timeout kills grandchildren holding the pipes — catches a hang after killing only the child")
  func timeoutKillsProcessGroup() async throws {
    let ready = try ReadyPipe()
    defer { ready.remove() }
    let clock = ShiftableClock()
    let patient = LiveProcessRunner(
      baseEnvironment: ["PATH": "/usr/bin:/bin"], terminationGracePeriod: .seconds(1),
      postExitDrainLimit: .seconds(3600), now: clock.now)
    let timeout = Duration.seconds(3600)
    let start = ContinuousClock.now
    let lifetime = Self.childLifetime
    let run = Task {
      await Self.outcome(
        patient,
        ProcessInvocation(
          executable: "/bin/sh",
          arguments: [
            "-c", "sleep \(lifetime) & echo ready > \"$READY\"; sleep \(lifetime); wait",
          ],
          environmentOverlay: ["READY": ready.path], timeout: timeout))
    }
    #expect(await ready.firstLine() == "ready")
    clock.advance(by: timeout)

    let result = await run.value
    #expect(ContinuousClock.now - start < Self.killedWell)
    guard case .failure(.timedOut) = result else {
      Issue.record("expected timedOut, got \(result)")
      return
    }
  }

  @Test("task cancellation kills the child — catches orphaned tools after a hook is interrupted")
  func cancellationKillsChild() async throws {
    let ready = try ReadyPipe()
    defer { ready.remove() }
    let start = ContinuousClock.now
    let task = Task {
      try await runner.run(
        ProcessInvocation(
          executable: "/bin/sh",
          arguments: ["-c", "echo ready > \"$READY\"; exec sleep \(Self.childLifetime)"],
          environmentOverlay: ["READY": ready.path], timeout: .seconds(3600)))
    }
    #expect(await ready.firstLine() == "ready")
    task.cancel()

    let result = await task.result
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

/// A named pipe a child writes one line to once it is actually running, so a test can move a
/// ``ShiftableClock`` past a timeout only once there is something to time out — never racing the
/// child's own startup against the machine's load. Kept in this file for the same reason as
/// ``ShiftableClock``.
private struct ReadyPipe {
  let path: String
  private let directory: URL

  init() throws {
    directory = FileManager.default.temporaryDirectory.appending(
      path: "swiftgate-ready-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    path = directory.appending(path: "ready").path
    guard mkfifo(path, 0o600) == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
  }

  func remove() { try? FileManager.default.removeItem(at: directory) }

  /// The first line written, read on a dedicated thread: opening the pipe for reading blocks
  /// until a writer opens it, so this can't run on a cooperative-pool thread.
  func firstLine() async -> String? {
    await withCheckedContinuation { continuation in
      Thread {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else {
          continuation.resume(returning: nil)
          return
        }
        defer { close(fd) }
        var pending: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 256)
        while true {
          let count = read(fd, &buffer, buffer.count)
          if count < 0, errno == EINTR { continue }
          if count <= 0 {
            continuation.resume(returning: nil)
            return
          }
          pending += buffer[0..<count]
          if let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            continuation.resume(returning: String(decoding: pending[..<newline], as: UTF8.self))
            return
          }
        }
      }.start()
    }
  }
}

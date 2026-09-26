import Foundation
import SwiftGateAdapters
import SwiftGateDomain
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

  @Test("timeout kills the child and throws a BLOCKED error — catches a hung tool wedging the gate")
  func timeoutKillsChild() async throws {
    let clock = ContinuousClock()
    let start = clock.now
    let error = await #expect(throws: ProcessRunnerError.self) {
      _ = try await runner.run(
        ProcessInvocation(
          executable: "/bin/sh", arguments: ["-c", "echo started; exec sleep 30"],
          timeout: .milliseconds(300)))
    }
    #expect(clock.now - start < .seconds(10))
    guard case .timedOut(_, let after, let stdout, _) = error else {
      Issue.record("expected timedOut, got \(String(describing: error))")
      return
    }
    #expect(after == .milliseconds(300))
    #expect(stdout.text == "started\n")
    #expect(error?.verdict == .blocked)
  }

  @Test(
    "timeout kills grandchildren holding the pipes — catches a hang after killing only the child")
  func timeoutKillsProcessGroup() async {
    let patient = LiveProcessRunner(
      baseEnvironment: ["PATH": "/usr/bin:/bin"], terminationGracePeriod: .seconds(1),
      postExitDrainLimit: .seconds(60))
    let clock = ContinuousClock()
    let start = clock.now
    await #expect(throws: ProcessRunnerError.self) {
      _ = try await patient.run(
        ProcessInvocation(
          executable: "/bin/sh", arguments: ["-c", "sleep 30 & sleep 30; wait"],
          timeout: .milliseconds(300)))
    }
    #expect(clock.now - start < .seconds(10))
  }

  @Test("task cancellation kills the child — catches orphaned tools after a hook is interrupted")
  func cancellationKillsChild() async {
    let clock = ContinuousClock()
    let start = clock.now
    let task = Task {
      try await runner.run(
        ProcessInvocation(executable: "/bin/sleep", arguments: ["30"], timeout: .seconds(60)))
    }
    task.cancel()
    let result = await task.result
    #expect(clock.now - start < .seconds(10))
    guard case .failure(let error) = result, case .cancelled = error as? ProcessRunnerError else {
      Issue.record("expected cancelled, got \(result)")
      return
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

import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

@testable import SwiftGateCLI

/// Proves the two CPU-time readings (``Latency/threadCPUMilliseconds(_:)`` for an in-process
/// hook, ``MeasuredProcessRunner`` for one that shells out) measure the hook under test and
/// nothing else: a hook made genuinely slower still fails its budget, and neither an external
/// process saturating every core nor another test's own CPU burner sharing this process can
/// inflate a reading that belongs to a different hook entirely.
@Suite("Hook latency budgets survive machine load")
struct HookLatencyCPUBudgetTests {
  /// Stands in for a hook's own `git` call having gotten slower: every invocation is redirected
  /// to a fixed-iteration shell busy loop (deterministic real CPU cost, not a sleep) that still
  /// answers with a `commonDirectory()`-shaped line, run through `measured` so its exact `wait4`
  /// rusage is what the test reads back.
  private struct SlowGitProcessRunner: ProcessRunner {
    let measured: MeasuredProcessRunner

    func run(_ invocation: ProcessInvocation) async throws(ProcessRunnerError) -> ProcessOutput {
      try await measured.run(
        ProcessInvocation(
          executable: "/bin/sh",
          arguments: ["-c", "n=0; while [ $n -lt 80000 ]; do n=$((n+1)); done; echo .git"],
          workingDirectory: invocation.workingDirectory, timeout: invocation.timeout))
    }
  }

  @Test(
    "a hook whose git call is made artificially slow still fails the CPU-time budget — catches the measurement papering over a real regression"
  )
  func slowGitCallFailsBudget() async throws {
    let harness = try HookHarness()
    defer { harness.repository.remove() }
    try harness.repository.write("docs/counter/designs/offline.md", "# Offline\n")
    let input = try harness.payload(
      "pre-tool-use-write-ledger",
      replacing: [
        PlanStateScenario.recordedPath: "\"\(harness.root.path)/docs/counter/designs/offline.md\""
      ])

    let samples = try await Latency.samples {
      let measured = MeasuredProcessRunner()
      let slowGit = LiveGit(
        runner: SlowGitProcessRunner(measured: measured), repositoryRoot: harness.root.path)
      let dependencies = HookDependencies(
        git: slowGit, swiftPM: harness.swiftPM, formatter: harness.formatter,
        xcode: harness.xcode, sweep: PendingOrphanCloneSweep(), commitJudge: harness.judge,
        environment: [:])
      _ = await HookRunner.run(.preToolUse, input: input) { _ in dependencies }
      return measured.totalChildCPUMilliseconds
    }
    #expect(
      samples.min()! >= 50,
      "an artificially slow git call should push every sample over budget: \(samples)ms")
  }

  @Test(
    "a holder's design-path Write stays under 50ms of CPU time with a warm plan-lock cache even when git is slow — catches the design guard spawning git on every call"
  )
  func warmCacheDesignWriteUnderBudget() async throws {
    let scenario = try PlanStateScenario()
    defer { scenario.harness.repository.remove() }
    try scenario.claim(PlanStateScenario.planA, by: PlanStateScenario.session)
    let input = try scenario.harness.payload(
      "pre-tool-use-write-ledger",
      replacing: [
        PlanStateScenario.recordedPath:
          "\"\(scenario.root.path)/\(PlanStateScenario.designA)\""
      ])
    let harness = scenario.harness
    let root = scenario.root
    func decide() async -> (result: HookResult, milliseconds: Int) {
      let measured = MeasuredProcessRunner()
      let dependencies = HookDependencies(
        git: LiveGit(runner: SlowGitProcessRunner(measured: measured), repositoryRoot: root.path),
        swiftPM: harness.swiftPM, formatter: harness.formatter, xcode: harness.xcode,
        sweep: PendingOrphanCloneSweep(), commitJudge: harness.judge, environment: [:])
      let (result, own) = await Latency.threadCPUMilliseconds {
        await HookRunner.run(.preToolUse, input: input) { _ in dependencies }
      }
      return (result, own + measured.totalChildCPUMilliseconds)
    }
    #expect(await decide().result == .silent)

    var results: [HookResult] = []
    let samples = await Latency.samples {
      let (result, milliseconds) = await decide()
      results.append(result)
      return milliseconds
    }
    #expect(results.allSatisfy { $0 == .silent }, "\(results)")
    #expect(samples.min()! < 50, "warm design-path samples: \(samples)ms, budget: 50ms")
  }

  @Test(
    "the fast PreToolUse path stays under its CPU-time budget while 4 CPU-burning processes load the machine — catches a wall-clock budget reddening under load with no code change"
  )
  func staysUnderBudgetWhileMachineIsBusy() async throws {
    let burners = (0..<4).map { _ -> Process in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      return process
    }
    for burner in burners { try burner.run() }
    defer { for burner in burners { burner.terminate() } }

    // A fresh scenario per sample so every repeat decides against the same, untouched plan
    // state, as PreToolUseGuardTests.ordinaryAndFast does. This hook path runs entirely
    // in-process against FakeGit, so its own thread's CPU time is the right reading.
    let samples = try await Latency.samples {
      let fresh = try PlanStateScenario()
      defer { fresh.harness.repository.remove() }
      let (_, milliseconds) = try await fresh.harness.run(
        .preToolUse, "pre-tool-use-write-ledger-subagent",
        replacing: [PlanStateScenario.recordedPath: "\"\(fresh.layout.indexFile)\""])
      return milliseconds
    }
    #expect(
      samples.min()! < 50,
      "a busy machine must not inflate the CPU-time reading: \(samples)ms, budget: 50ms")
  }

  @Test(
    "another test's CPU burner running concurrently in this same process doesn't count toward the measured hook — catches a process-wide reading picking up unrelated work"
  )
  func concurrentBurnerDoesNotInflateThreadTime() async throws {
    let keepBurning = Mutex(true)
    // A real OS thread, not a Swift Task: the point is load sharing this xctest *process*
    // outside the Swift concurrency pool entirely, the way an unrelated parallel test would.
    let burner = Thread {
      var sink: UInt64 = 0
      while keepBurning.withLock({ $0 }) {
        sink = sink &+ 1
      }
      withExtendedLifetime(sink) {}
    }
    burner.start()
    defer { keepBurning.withLock { $0 = false } }

    let harness = try HookHarness()
    defer { harness.repository.remove() }
    let samples = try await Latency.samples {
      let (_, milliseconds) = try await harness.run(.preToolUse, "pre-tool-use-bash-allowed")
      return milliseconds
    }
    #expect(
      samples.min()! < 50,
      "a same-process CPU burner inflated the reading: \(samples)ms, budget: 50ms")
  }
}

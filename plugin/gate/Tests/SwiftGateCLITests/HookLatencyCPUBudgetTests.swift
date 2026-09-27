import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// Proves ``Latency/cpuMilliseconds(_:)`` measures a hook's own cost, not the machine's: a hook
/// made genuinely slower still fails the budget, while a hook whose cost never changed keeps
/// passing even while other processes saturate the CPU.
@Suite("Hook latency budgets survive machine load")
struct HookLatencyCPUBudgetTests {
  /// Spins the CPU (not the clock) for at least `duration`, so the cost lands on this thread's
  /// own CPU-time accounting rather than on a sleep the scheduler could satisfy for free.
  private static func burnCPU(for duration: Duration) {
    let clock = ContinuousClock()
    let deadline = clock.now + duration
    var sink: UInt64 = 0
    while clock.now < deadline {
      sink = sink &+ 1
    }
    withExtendedLifetime(sink) {}
  }

  @Test(
    "a hook whose git call is made artificially slow still fails the CPU-time budget — catches the CPU-time measurement papering over a real regression"
  )
  func slowGitCallFailsBudget() async throws {
    let harness = try HookHarness()
    defer { harness.repository.remove() }
    try harness.repository.write("docs/counter/designs/offline.md", "# Offline\n")

    // A test-only Git that answers `rev-parse --git-common-dir` correctly, but only after
    // burning real CPU first — standing in for a hook whose own logic, or a child process it
    // spawns, got slower.
    let slowGit = LiveGit(
      runner: FakeProcessRunner { _ in
        Self.burnCPU(for: .milliseconds(120))
        return ProcessOutput(status: .exited(0), stdout: ".git\n")
      },
      repositoryRoot: harness.root.path)
    let dependencies = HookDependencies(
      git: slowGit, swiftPM: harness.swiftPM, formatter: harness.formatter, xcode: harness.xcode,
      sweep: PendingOrphanCloneSweep(), commitJudge: harness.judge, environment: [:])
    let input = try harness.payload(
      "pre-tool-use-write-ledger",
      replacing: [
        PlanStateScenario.recordedPath: "\"\(harness.root.path)/docs/counter/designs/offline.md\""
      ])

    let samples = await Latency.samples {
      let (_, milliseconds) = await Latency.cpuMilliseconds {
        await HookRunner.run(.preToolUse, input: input) { _ in dependencies }
      }
      return milliseconds
    }
    #expect(
      samples.min()! >= 50,
      "an artificially slow git call should push every sample over budget: \(samples)ms")
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
    // state, as PreToolUseGuardTests.ordinaryAndFast does.
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
}

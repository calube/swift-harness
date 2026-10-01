import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// Shared driver for T0 commands: times the check, builds and records the report, prints it, and
/// exits with the verdict's status.
enum StaticCheckRun {
  /// - Parameters:
  ///   - command: the command that ran, for its `gate.run` event.
  ///   - events: where the run's events go; `nil` asks `.swiftgate.toml`'s `[telemetry]`.
  ///   - workingTree: reads the tree the run starts on; `nil` asks git in `root`.
  static func execute(
    root: URL, format: OutputFormat, runID: String? = nil, command: String? = nil,
    events: (any HarnessEventWriting)? = nil, workingTree: (any WorkingTreeReading)? = nil,
    check: () async -> StaticCheckOutcome
  ) async throws {
    let clock = ContinuousClock()
    let startedAt = Date()
    let start = clock.now
    let telemetry = await GateRun.telemetry(root: root, events: events, workingTree: workingTree)
    let outcome = await check()
    let elapsed = clock.now - start
    let milliseconds =
      Int(elapsed.components.seconds * 1000)
      + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
    let runID = runID ?? RunID.make(startedAt: startedAt, suffix: UInt32.random(in: .min ... .max))
    let report = try StaticCheckReport.make(
      runID: runID, durationMilliseconds: milliseconds, outcome: outcome)
    // History is diagnostics; failing to write it must not flip a verdict about the code.
    GateRun.record { () throws(RunStoreError) in
      try RunStore(worktreeRoot: root, events: telemetry.events).record(
        report, finishedAt: Date(), command: command, treeHash: telemetry.tree?.treeHash,
        dirty: telemetry.tree?.dirty)
    }
    Console.write(try ReportRenderer.render(report, format: format))
    let status = report.verdict.exitCode
    if status != 0 { throw ExitCode(status) }
  }
}

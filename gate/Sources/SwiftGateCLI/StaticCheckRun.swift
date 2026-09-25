import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// Shared driver for T0 commands: times the check, builds and records the report, prints it, and
/// exits with the verdict's status.
enum StaticCheckRun {
  static func execute(
    root: URL, format: OutputFormat, check: () async -> StaticCheckOutcome
  ) async throws {
    let clock = ContinuousClock()
    let startedAt = Date()
    let start = clock.now
    let outcome = await check()
    let elapsed = clock.now - start
    let milliseconds =
      Int(elapsed.components.seconds * 1000)
      + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
    let runID = RunID.make(startedAt: startedAt, suffix: UInt32.random(in: .min ... .max))
    let report = try StaticCheckReport.make(
      runID: runID, durationMilliseconds: milliseconds, outcome: outcome)
    do {
      try RunStore(worktreeRoot: root).record(report, finishedAt: Date())
    } catch {
      // History is diagnostics; failing to write it must not flip a verdict about the code.
      FileHandle.standardError.write(Data("swiftgate: could not record run: \(error)\n".utf8))
    }
    print(try ReportRenderer.render(report, format: format))
    let status = report.verdict.exitCode
    if status != 0 { throw ExitCode(status) }
  }
}

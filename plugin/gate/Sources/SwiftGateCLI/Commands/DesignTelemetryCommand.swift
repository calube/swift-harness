import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// What `design-telemetry` prints: the phase line it appended and the telemetry file it wrote,
/// both relative to the repository root.
struct DesignTelemetryReport: Sendable, Equatable, Encodable {
  let command = "design-telemetry"
  let phasesFile: String
  let telemetryFile: String
  let phaseRecord: PhaseRecord
  let telemetry: DesignTelemetryRecord

  static func render(_ report: DesignTelemetryReport, format: OutputFormat) -> String {
    switch format {
    case .json:
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      return String(decoding: (try? encoder.encode(report)) ?? Data(), as: UTF8.self)
    case .human:
      let tokens = report.phaseRecord.tokens.map { "\($0) output tokens" } ?? "tokens unmeasured"
      return
        "design-telemetry: \(report.phaseRecord.phase.rawValue) \(tokens), "
        + "\(ReportRenderer.duration(report.phaseRecord.wallMilliseconds)) wall; "
        + "appended to \(report.phasesFile), wrote \(report.telemetryFile)"
    }
  }
}

/// The body of `design-telemetry`, factored out of the `ParsableCommand` so tests pass the clock.
enum DesignTelemetryRun {
  struct Options: Sendable, Equatable {
    var runDirectory: String?
    var runID: String?
    var phase: String?
    var workflowResult: String?
    var startedAt: String?
    var session: String?
  }

  enum Outcome: Sendable, Equatable {
    case recorded(DesignTelemetryReport)
    case failed(message: String)
  }

  static func run(options: Options, root: URL, now: Date) -> Outcome {
    .failed(message: "not implemented")
  }
}

struct DesignTelemetryCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "design-telemetry",
    abstract: "Record one design workflow run's telemetry in the design run's directory.",
    discussion:
      "Reads the telemetry a design workflow (design-research.js or design-review.js) returned, "
      + "appends 1 schema 2 line to <run>/phases.jsonl and writes <run>/telemetry/<phase>-<n>.json "
      + "with the workflow's telemetry and, with --session, the session record's transcript path. "
      + "Wall time runs from --started-at to now. Tokens no tool reported are null with a reason, "
      + "never 0. Exit 0 recorded; exit 2 on a missing option, an unknown phase, a bad run id or "
      + "start time, a missing run directory, or an unreadable workflow result.")

  @Option(name: .customLong("run"), help: "The design run directory, .harness/runs/design-<slug>.")
  var runDirectory: String?

  @Option(name: .customLong("run-id"), help: "The design run id, design-<yyyyMMddTHHmmssZ>.")
  var runID: String?

  @Option(help: "The phase the workflow ran in: research, review, revise or amend.")
  var phase: String?

  @Option(
    name: .customLong("workflow-result"), help: "The workflow's return value saved as JSON.")
  var workflowResult: String?

  @Option(
    name: .customLong("started-at"),
    help: "When the workflow was launched, as ISO 8601 UTC (date -u +%Y-%m-%dT%H:%M:%SZ).")
  var startedAt: String?

  @Option(help: "This session's id; its session record names the transcript file.")
  var session: String?

  @OptionGroup var output: OutputOptions

  func run() throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let outcome = DesignTelemetryRun.run(
      options: .init(
        runDirectory: runDirectory, runID: runID, phase: phase, workflowResult: workflowResult,
        startedAt: startedAt, session: session),
      root: root, now: Date())
    switch outcome {
    case .recorded(let report):
      Console.write(DesignTelemetryReport.render(report, format: output.format))
    case .failed(let message):
      FileHandle.standardError.write(Data("swiftgate design-telemetry: \(message)\n".utf8))
      throw ExitCode(Verdict.blocked.exitCode)
    }
  }
}

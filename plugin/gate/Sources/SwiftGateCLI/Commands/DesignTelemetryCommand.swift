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
    do {
      return .recorded(try record(options: options, root: root, now: now))
    } catch {
      return .failed(message: error.description)
    }
  }

  struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
  }

  private static func required(_ value: String?, _ flag: String) throws(Failure) -> String {
    guard let value, !value.isEmpty else { throw Failure("missing required option '\(flag)'") }
    return value
  }

  private static func record(options: Options, root: URL, now: Date) throws(Failure)
    -> DesignTelemetryReport
  {
    let run = try required(options.runDirectory, "--run")
    let runID = try required(options.runID, "--run-id")
    let phaseName = try required(options.phase, "--phase")
    let resultPath = try required(options.workflowResult, "--workflow-result")
    let startedText = try required(options.startedAt, "--started-at")

    let phase: DesignPlanPhase
    do {
      try DesignTelemetry.validateRunID(runID)
      phase = try DesignTelemetry.phase(named: phaseName)
    } catch {
      throw Failure(error.description)
    }
    guard let started = parseDate(startedText) else {
      throw Failure(
        DesignTelemetryError.invalidStartedAt("`\(startedText)` is not an ISO 8601 time")
          .description)
    }
    let runURL =
      run.hasPrefix("/")
      ? URL(filePath: run, directoryHint: .isDirectory)
      : root.appending(path: run, directoryHint: .isDirectory)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: runURL.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw Failure("--run `\(run)` is not a directory; the frame step creates it")
    }

    let data: Data
    do {
      data = try Data(contentsOf: URL(filePath: resultPath))
    } catch {
      throw Failure(
        DesignTelemetryError.unreadableResult(
          "`\(resultPath)` can't be read: \(error.localizedDescription)"
        ).description)
    }
    let workflow: WorkflowTelemetry
    do {
      workflow = try DesignTelemetry.decodeResult(data)
    } catch {
      throw Failure(error.description)
    }

    let session = try sessionTranscript(options.session, root: root)
    let made: (phase: PhaseRecord, telemetry: DesignTelemetryRecord)
    do {
      made = try DesignTelemetry.make(
        runId: runID, phase: phase, startedAt: started, finishedAt: now, workflow: workflow,
        session: session)
    } catch {
      throw Failure(error.description)
    }

    let telemetryName = try writeTelemetry(made.telemetry, phase: phase, runURL: runURL)
    let phasesName = "phases.jsonl"
    try appendLine(made.phase, to: runURL.appending(path: phasesName))
    let prefix = run.hasSuffix("/") ? String(run.dropLast()) : run
    return DesignTelemetryReport(
      phasesFile: "\(prefix)/\(phasesName)",
      telemetryFile: "\(prefix)/\(DesignTelemetryRecord.directoryName)/\(telemetryName)",
      phaseRecord: made.phase, telemetry: made.telemetry)
  }

  private static func parseDate(_ text: String) -> Date? {
    let plain = ISO8601DateFormatter()
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return plain.date(from: text) ?? fractional.date(from: text)
  }

  /// An unsafe id names no file, so it stops the command; a record that is missing or unreadable
  /// is a named gap in the telemetry file.
  private static func sessionTranscript(_ id: String?, root: URL) throws(Failure)
    -> SessionTranscript
  {
    guard let id else { return .notRequested }
    let store = SessionRecordStore(worktreeRoot: root)
    do {
      guard let record = try store.record(sessionID: id) else {
        return .unreadable(
          sessionId: id,
          reason: "no session record at \(store.displayDirectory)/\(id).json")
      }
      return .recorded(sessionId: id, transcriptPath: record.transcriptPath)
    } catch {
      if case .unsafeSessionID = error { throw Failure("--session: \(error.description)") }
      return .unreadable(sessionId: id, reason: error.description)
    }
  }

  /// `<phase>-<n>.json` with the next free `n`, created without overwriting, so two runs of the
  /// same phase never share a file.
  private static func writeTelemetry(
    _ record: DesignTelemetryRecord, phase: DesignPlanPhase, runURL: URL
  ) throws(Failure) -> String {
    let directory = runURL.appending(
      path: DesignTelemetryRecord.directoryName, directoryHint: .isDirectory)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let data = try encoder.encode(record) + Data("\n".utf8)
      let existing = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      let prefix = "\(phase.rawValue)-"
      var next =
        (existing.compactMap { name -> Int? in
          guard name.hasPrefix(prefix), name.hasSuffix(".json") else { return nil }
          return Int(name.dropFirst(prefix.count).dropLast(".json".count))
        }.max() ?? 0) + 1
      while true {
        let name = "\(prefix)\(next).json"
        do {
          try data.write(to: directory.appending(path: name), options: .withoutOverwriting)
          return name
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
          next += 1
        }
      }
    } catch {
      throw Failure("can't write \(directory.path): \(error.localizedDescription)")
    }
  }

  private static func appendLine(_ record: PhaseRecord, to url: URL) throws(Failure) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    do {
      let line = try encoder.encode(record) + Data("\n".utf8)
      if !FileManager.default.fileExists(atPath: url.path) {
        try Data().write(to: url, options: .withoutOverwriting)
      }
      let handle = try FileHandle(forWritingTo: url)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: line)
    } catch let error as CocoaError where error.code == .fileWriteFileExists {
      try appendLine(record, to: url)
    } catch {
      throw Failure("can't append to \(url.path): \(error.localizedDescription)")
    }
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

import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// What `evidence capture` did: it always succeeds once the command ran to an exit status,
/// whatever that status was — a failing captured command is still evidence, faithfully stored
/// (spec §6.1, §6.2). Only an environment problem (bad `--design`, no command, a launch or write
/// failure) is `blocked`.
struct EvidenceCaptureReport: Sendable, Equatable, Encodable {
  let command = "evidence capture"
  let verdict: Verdict
  let design: String
  let argv: [String]
  let capturePath: String?
  let citation: Citation?
  /// The captured command's real process status, or `nil` when no capture ran (a blocked
  /// report). `ExitStatus` isn't itself `Codable`, so this is encoded explicitly as a single-key
  /// object naming which case it is: `{"exited": <code>}` or `{"signaled": <signal>}` — never a
  /// 0 standing in for "not known".
  let status: ExitStatus?
  let message: String

  private enum CodingKeys: String, CodingKey {
    case command, verdict, design, argv, capturePath, citation, status, message
  }

  private enum StatusCodingKeys: String, CodingKey {
    case exited, signaled
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(command, forKey: .command)
    try container.encode(verdict, forKey: .verdict)
    try container.encode(design, forKey: .design)
    try container.encode(argv, forKey: .argv)
    try container.encodeIfPresent(capturePath, forKey: .capturePath)
    try container.encodeIfPresent(citation, forKey: .citation)
    if let status {
      var statusContainer = container.nestedContainer(
        keyedBy: StatusCodingKeys.self, forKey: .status)
      switch status {
      case .exited(let code): try statusContainer.encode(code, forKey: .exited)
      case .signaled(let signal): try statusContainer.encode(signal, forKey: .signaled)
      }
    } else {
      try container.encodeNil(forKey: .status)
    }
    try container.encode(message, forKey: .message)
  }
}

enum EvidenceCaptureRun {
  static func capture(
    design: String, argv: [String], workingDirectory: URL, runner: any ProcessRunner
  ) async -> EvidenceCaptureReport {
    guard PlanFile.isValidDesignPath(design) else {
      return blocked(
        design: design, argv: argv,
        "--design `\(design)` must be a repo-relative docs/**/designs/<name>.md path")
    }
    guard !argv.isEmpty else {
      return blocked(design: design, argv: argv, "no command given: pass it after --")
    }

    let layout = EvidenceLayout(designDocPath: design)
    let evidenceRoot = workingDirectory.appending(
      path: layout.capturesDirectory, directoryHint: .isDirectory)
    let outcome = await EvidenceCapture.run(
      argv: argv, evidenceRoot: evidenceRoot,
      repoRelativeCapturesDirectory: layout.capturesDirectory,
      workingDirectory: workingDirectory.path, runner: runner)

    switch outcome {
    case .failure(let failure):
      return blocked(design: design, argv: argv, describe(failure))
    case .success(let result):
      return EvidenceCaptureReport(
        verdict: .green, design: design, argv: argv, capturePath: result.capturePath,
        citation: result.citation, status: result.status,
        message:
          "captured `\(argv.joined(separator: " "))` (\(describe(result.status))) at "
          + result.capturePath)
    }
  }

  static func render(_ report: EvidenceCaptureReport, format: OutputFormat) -> String {
    switch format {
    case .json:
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      let data = (try? encoder.encode(report)) ?? Data()
      return String(decoding: data, as: UTF8.self)
    case .human:
      var lines = ["evidence capture: \(report.verdict.rawValue) \(report.message)"]
      if let citation = report.citation {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(citation) {
          lines.append(String(decoding: data, as: UTF8.self))
        }
      }
      return lines.joined(separator: "\n")
    }
  }

  private static func describe(_ failure: EvidenceCapture.Failure) -> String {
    switch failure {
    case .emptyCommand: "no command given: pass it after --"
    case .process(let detail): detail
    case .io(let detail): detail
    }
  }

  private static func describe(_ status: ExitStatus) -> String {
    switch status {
    case .exited(let code): "exit \(code)"
    case .signaled(let signal): "signal \(signal)"
    }
  }

  private static func blocked(design: String, argv: [String], _ message: String)
    -> EvidenceCaptureReport
  {
    EvidenceCaptureReport(
      verdict: .blocked, design: design, argv: argv, capturePath: nil, citation: nil, status: nil,
      message: message)
  }
}

struct EvidenceCaptureCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "capture",
    abstract: "Run a command and store its output, hash and citation as a capture claim.")

  @Option(help: "The design doc whose <slug>.evidence/ store receives this capture.")
  var design: String

  @Argument(parsing: .remaining, help: "The command to run and capture, after --.")
  var command: [String] = []

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let report = await EvidenceCaptureRun.capture(
      design: design, argv: command, workingDirectory: root, runner: LiveProcessRunner())
    Console.write(EvidenceCaptureRun.render(report, format: output.format))
    if report.verdict != .green { throw ExitCode(report.verdict.exitCode) }
  }
}

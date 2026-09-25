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
  let exitedWith: Int32?
  let signaledWith: Int32?
  let message: String
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
      let status = result.signaledWith.map { "signal \($0)" } ?? "exit \(result.exitedWith ?? 0)"
      return EvidenceCaptureReport(
        verdict: .green, design: design, argv: argv, capturePath: result.capturePath,
        citation: result.citation, exitedWith: result.exitedWith,
        signaledWith: result.signaledWith,
        message: "captured `\(argv.joined(separator: " "))` (\(status)) at \(result.capturePath)")
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

  private static func blocked(design: String, argv: [String], _ message: String)
    -> EvidenceCaptureReport
  {
    EvidenceCaptureReport(
      verdict: .blocked, design: design, argv: argv, capturePath: nil, citation: nil,
      exitedWith: nil, signaledWith: nil, message: message)
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

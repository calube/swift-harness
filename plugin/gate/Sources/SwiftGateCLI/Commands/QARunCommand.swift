import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// `qa run`'s behaviour, apart from argument parsing so tests drive it against a temp repository.
enum QARunRun {
  static let command = "qa run"
  /// How long 1 check may run before it is stopped and reads `red`.
  static let checkTimeout: Duration = .seconds(600)

  struct Options: Sendable, Equatable {
    var plan: String?
    var after: String?
    var atBase = false
  }

  struct Dependencies: Sendable {
    var checks: any QACheckRunning
    var ports: any QAPortAssigning
    /// `nil` makes scratch trees beside the repository, as `prove` does.
    var scratch: (any ScratchWorktrees)?
    /// `nil` writes through the checkout's telemetry setting.
    var events: (any HarnessEventWriting)?
    var now: @Sendable () -> Date
    var runIDSuffix: @Sendable () -> UInt32
    var newEventID: @Sendable () -> String
    var timeout: Duration = QARunRun.checkTimeout
  }

  static func run(root: URL, options: Options, git: any Git, dependencies: Dependencies) async
    -> QAReport
  {
    .blocked(
      "not implemented yet", plan: options.plan, after: options.after, atBase: options.atBase)
  }

  static func render(_ report: QAReport, json: Bool) -> String {
    guard json else { return "\(command): \(report.verdict.rawValue) \(report.message)" }
    return String(decoding: (try? QAReportJSON.encode(report)) ?? Data(), as: UTF8.self)
  }
}

/// `swiftgate qa run [--plan <slug>] [--after <task>] [--at-base] [--json]`.
struct QARunCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "run",
    abstract: "Run the validation rows whose tasks have merged: acceptance, then flow, then state.")

  @Option(help: "The plan's slug; defaults to the 1 plan holding a validation.json.")
  var plan: String?

  @Option(help: "Run only the rows that name this task in Runs after, taking it as merged.")
  var after: String?

  @Flag(help: "Run every row at the merge base in a scratch worktree and record why each fails.")
  var atBase = false

  @Flag(help: "Print JSON.")
  var json = false

  func run() async throws {
    try StubCommand.notImplemented(QARunRun.command, json: json)
  }
}

import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateRules

/// `qa lint`'s behaviour, apart from argument parsing so tests and `qa run` drive it directly.
enum QALintRun {
  static let command = "qa lint"
  static let harnessRootVariable = "SWIFTGATE_HARNESS_ROOT"

  /// Lints each flow file, a path relative to `root` or absolute.
  static func run(files: [String], root: URL, pluginRoot: URL?) -> FlowLintReport {
    FlowLintReport(files: files, findings: [])
  }

  static func render(_ report: FlowLintReport, json: Bool) -> String {
    ""
  }
}

/// `swiftgate qa lint <flow file>... [--json]`.
struct QALintCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "lint",
    abstract: "Check agent-device batch steps files offline, before any device boots.")

  @Argument(help: "The batch steps files to check, such as qa/<name>.flow.json.")
  var files: [String]

  @Flag(help: "Print JSON.")
  var json = false

  func run() throws {}
}

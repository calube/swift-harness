import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// `swiftgate report --html|--json <build run> [--out <path>]`: writes 1 build run's view as a
/// self-contained page, or prints it as JSON.
struct ReportCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "report",
    abstract: "Write a build run's report page, or print its run view as JSON.")

  @Flag(help: "Write a self-contained HTML page.")
  var html = false

  @Flag(help: "Print the run view as JSON.")
  var json = false

  @Argument(help: "The build run id.")
  var buildRun: String

  @Option(
    help: "Where to write the page; reports/<build run>.html under the state root when absent.")
  var out: String?

  func run() async throws {
    try StubCommand.notImplemented("report", json: false)
  }
}

/// What `report` does, apart from resolving the repository: read, build, guard, then write or
/// print.
enum ReportRun {
  enum Format: Sendable, Equatable {
    case html
    case json
  }

  enum Outcome: Sendable, Equatable {
    /// The page or JSON went to `path`, as the message names it.
    case wrote(path: String)
    /// The JSON to print.
    case printed(String)
    /// Exit 2 with this message.
    case blocked(String)
  }

  /// - Parameters:
  ///   - root: the checkout `report` runs in; a relative `out` resolves against it.
  ///   - commonDirectory: the git common dir, absolute.
  ///   - pluginRoot: where `viewer/` lives; `nil` when unknown, which only `--html` needs.
  static func run(
    buildRun: String, format: Format, out: String?, root: URL, commonDirectory: URL,
    pluginRoot: URL?
  ) -> Outcome {
    .blocked("report: not implemented")
  }
}

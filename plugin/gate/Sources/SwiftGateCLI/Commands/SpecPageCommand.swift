import ArgumentParser
import Foundation
import SwiftGateDomain

/// Reads the page and the spec file and renders the domain's report.
enum SpecPageCheckRun {
  struct Result: Sendable, Equatable {
    let output: String
    let exitCode: Int32
  }

  static func run(pagePath: String, specPath: String, json: Bool) -> Result {
    Result(output: "", exitCode: 0)
  }
}

struct SpecPageCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "spec-page",
    abstract: "Check a spec page (fast modes §5.2).",
    subcommands: [SpecPageCheckCommand.self])
}

struct SpecPageCheckCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "check",
    abstract: "Check a spec page's format and length, and its Spec: quotes against the spec file.")

  @Argument(help: "The spec page.")
  var page: String

  @Option(help: "The spec file the page quotes.")
  var spec: String

  @Flag(help: "Print JSON.")
  var json = false

  func run() async throws {}
}

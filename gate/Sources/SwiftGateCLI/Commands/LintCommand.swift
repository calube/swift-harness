import ArgumentParser
import Foundation
import SwiftGateDomain
import SwiftGateRules

/// Determinism, client-boundary, observability, escape-hatch and banned-API rules.
enum LintCheck {
  static func run(root: URL, paths: [String]) -> StaticCheckOutcome {
    switch StaticCheckInputs.load(root: root, paths: paths) {
    case .failed(let outcome):
      return outcome
    case .loaded(let config, let sources):
      let context = RuleContext(
        scopes: PathConventionModuleScopes(),
        vendorModules: config?.clients.vendorModules ?? [])
      return StaticCheck.evaluate(RuleCatalog.lint, sources, context: context)
    }
  }
}

struct LintCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "lint",
    abstract: "Check determinism, client boundaries, logging, escape hatches and banned APIs.")

  @Argument(help: "Files or directories to check, relative to the repository root. Default: all.")
  var paths: [String] = []

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    try await StaticCheckRun.execute(root: root, format: output.format) {
      LintCheck.run(root: root, paths: paths)
    }
  }
}

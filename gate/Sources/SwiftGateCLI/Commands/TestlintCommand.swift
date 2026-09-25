import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateRules

/// Static useless-test detection over test files (spec §7.4) plus T3 flow placement.
enum TestlintCheck {
  static func run(root: URL, paths: [String]) -> StaticCheckOutcome {
    let config: Config?
    let sources: [SourceInput]
    switch StaticCheckInputs.load(root: root, paths: paths) {
    case .loaded(let loadedConfig, let loadedSources):
      (config, sources) = (loadedConfig, loadedSources)
    case .failed(let outcome): return outcome
    }
    let context = RuleContext(
      scopes: PathConventionModuleScopes(), flows: config.map { $0.flows.map(\.name) })
    return StaticCheck.evaluate(
      RuleCatalog.testlint, sources, context: context)
  }
}

struct TestlintCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "testlint",
    abstract: "Flag tests that cannot catch regressions, and misplaced UI tests.")

  @Argument(help: "Files or directories to check, relative to the repository root. Default: all.")
  var paths: [String] = []

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    try await StaticCheckRun.execute(root: root, format: output.format) {
      TestlintCheck.run(root: root, paths: paths)
    }
  }
}

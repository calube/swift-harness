import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateRules

/// Determinism, client-boundary, observability, escape-hatch and banned-API rules.
enum LintCheck {
  static func run(root: URL, paths: [String], swiftPM: any SwiftPM) async -> StaticCheckOutcome {
    let inputs: StaticCheckInputs.Loaded
    switch await StaticCheckInputs.load(root: root, paths: paths, swiftPM: swiftPM) {
    case .failed(let outcome): return outcome
    case .loaded(let loaded): inputs = loaded
    }
    let context = RuleContext(
      scopes: inputs.scopes.resolver, vendorModules: inputs.config?.clients.vendorModules ?? [])
    return inputs.scopes.appendingNotices(
      to: StaticCheck.evaluate(RuleCatalog.lint, inputs.sources, context: context))
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
      await LintCheck.run(
        root: root, paths: paths, swiftPM: ScopeResolution.liveSwiftPM(root: root))
    }
  }
}

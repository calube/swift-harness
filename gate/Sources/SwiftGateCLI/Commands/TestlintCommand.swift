import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateRules

/// Static useless-test detection over test files (spec §7.4) plus T3 flow placement.
enum TestlintCheck {
  static func run(root: URL, paths: [String], swiftPM: any SwiftPM) async -> StaticCheckOutcome {
    let inputs: StaticCheckInputs.Loaded
    switch await StaticCheckInputs.load(root: root, paths: paths, swiftPM: swiftPM) {
    case .failed(let outcome): return outcome
    case .loaded(let loaded): inputs = loaded
    }
    return evaluate(inputs)
  }

  static func evaluate(_ inputs: StaticCheckInputs.Loaded) -> StaticCheckOutcome {
    let context = RuleContext(
      scopes: inputs.scopes.resolver, flows: inputs.config.map { $0.flows.map(\.name) })
    return inputs.scopes.appendingNotices(
      to: StaticCheck.evaluate(RuleCatalog.testlint, inputs.sources, context: context))
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
      await TestlintCheck.run(
        root: root, paths: paths, swiftPM: ScopeResolution.liveSwiftPM(root: root))
    }
  }
}

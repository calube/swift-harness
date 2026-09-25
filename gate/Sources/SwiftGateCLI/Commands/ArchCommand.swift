import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateRules

/// Architecture rules (spec §6.1): client boundaries and module kinds from the module graph, plus
/// the source-level facts (imports, `@Reducer`, test values) the graph cannot show.
enum ArchCheck {
  /// Every rule `arch` can report, source-level and graph-level.
  static var ruleIDs: [String] {
    RuleCatalog.arch.map(\.descriptor.id) + ArchitectureRules.all.map(\.id)
  }

  static func run(root: URL, swiftPM: any SwiftPM) async -> StaticCheckOutcome {
    let inputs: StaticCheckInputs.Loaded
    switch await StaticCheckInputs.load(root: root, paths: [], swiftPM: swiftPM) {
    case .failed(let outcome): return outcome
    case .loaded(let loaded): inputs = loaded
    }
    return await evaluate(inputs, swiftPM: swiftPM)
  }

  static func evaluate(_ inputs: StaticCheckInputs.Loaded, swiftPM: any SwiftPM) async
    -> StaticCheckOutcome
  {
    let sourceOutcome = StaticCheck.evaluate(
      RuleCatalog.arch, inputs.sources, context: RuleContext(scopes: inputs.scopes.resolver))
    guard case .checked(let sourceResult) = sourceOutcome else { return sourceOutcome }
    guard let graph = inputs.scopes.graph, let config = inputs.config else {
      return inputs.scopes.appendingNotices(to: sourceOutcome)
    }

    let settings: [String: PackageSettings]
    switch await loadSettings(graph: graph, swiftPM: swiftPM) {
    case .success(let loaded): settings = loaded
    case .failure(let failure): return .blocked(reason: failure.reason)
    }
    do {
      let graphFindings = try ArchitectureRules.evaluate(
        ArchitectureInput(graph: graph, config: config, settings: settings))
      return .checked(
        RuleRunResult(
          findings: sourceResult.findings + graphFindings, allowances: sourceResult.allowances))
    } catch {
      return .blocked(reason: "arch: \(error)")
    }
  }

  private static func loadSettings(graph: ModuleGraph, swiftPM: any SwiftPM) async
    -> Result<[String: PackageSettings], SettingsFailure>
  {
    await withTaskGroup(of: (String, Result<PackageSettings, SwiftPMError>).self) { group in
      for package in graph.packages {
        group.addTask {
          do throws(SwiftPMError) {
            return (
              package.path, .success(try await swiftPM.settings(packageDirectory: package.path))
            )
          } catch {
            return (package.path, .failure(error))
          }
        }
      }
      var settings: [String: PackageSettings] = [:]
      var firstFailure: SettingsFailure?
      for await (path, result) in group {
        switch result {
        case .success(let value): settings[path] = value
        case .failure(let error):
          firstFailure =
            firstFailure
            ?? SettingsFailure(reason: "swift package dump-package failed in \(path): \(error)")
        }
      }
      if let firstFailure { return .failure(firstFailure) }
      return .success(settings)
    }
  }
}

struct SettingsFailure: Error {
  let reason: String
}

struct ArchCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "arch",
    abstract: "Check module boundaries, kinds and client test values against the module graph.")

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    try await StaticCheckRun.execute(root: root, format: output.format) {
      await ArchCheck.run(root: root, swiftPM: ScopeResolution.liveSwiftPM(root: root))
    }
  }
}

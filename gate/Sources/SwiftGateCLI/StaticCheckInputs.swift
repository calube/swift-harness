import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateRules

/// What a path-based T0 check reads before running rules: the repository config (absent is
/// allowed), the module scopes it implies, and the Swift files under the requested paths.
enum StaticCheckInputs {
  struct Loaded: Sendable {
    let config: Config?
    let sources: [SourceInput]
    let scopes: ResolvedScopes
  }

  case loaded(Loaded)
  case failed(StaticCheckOutcome)

  /// An empty `paths` means the whole repository.
  static func load(root: URL, paths: [String], swiftPM: any SwiftPM) async -> StaticCheckInputs {
    let config: Config?
    switch loadConfig(root: root) {
    case .success(let loaded): config = loaded
    case .failure(let failure): return .failed(failure.outcome)
    }
    let sources: [SourceInput]
    do throws(SourceCollectionError) {
      let collected = try SwiftSourceCollector(root: root).collect(
        paths: paths.isEmpty ? ["."] : paths)
      sources = collected.map { SourceInput(path: $0.path, text: $0.text) }
    } catch {
      return .failed(.blocked(reason: "sources: \(error)"))
    }
    switch await ScopeResolution.resolve(config: config, root: root, swiftPM: swiftPM) {
    case .failed(let outcome): return .failed(outcome)
    case .resolved(let scopes):
      return .loaded(Loaded(config: config, sources: sources, scopes: scopes))
    }
  }

  struct ConfigFailure: Error {
    let outcome: StaticCheckOutcome
  }

  static func loadConfig(root: URL) -> Result<Config?, ConfigFailure> {
    do throws(ConfigLoadError) {
      return .success(try ConfigLoader().load(repositoryRoot: root))
    } catch {
      switch error.verdict {
      case .red: return .failure(ConfigFailure(outcome: .invalid(reason: error.description)))
      case .blocked, .green:
        return .failure(ConfigFailure(outcome: .blocked(reason: error.description)))
      }
    }
  }
}

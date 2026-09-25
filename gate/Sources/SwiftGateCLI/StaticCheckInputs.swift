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

  /// An empty `paths` means the whole repository, minus the config's `exclude` directories.
  static func load(root: URL, paths: [String], swiftPM: any SwiftPM) async -> StaticCheckInputs {
    let config: Config?
    switch loadConfig(root: root) {
    case .success(let loaded): config = loaded
    case .failure(let failure): return .failed(failure.outcome)
    }
    switch await ScopeResolution.resolve(config: config, root: root, swiftPM: swiftPM) {
    case .failed(let outcome): return .failed(outcome)
    case .resolved(let scopes):
      return collect(root: root, paths: paths, config: config, scopes: scopes)
    }
  }

  /// Reads the sources for an already-resolved config and scopes, so several checks in one run
  /// describe the packages once.
  static func collect(root: URL, paths: [String], config: Config?, scopes: ResolvedScopes)
    -> StaticCheckInputs
  {
    do throws(SourceCollectionError) {
      let collected = try SwiftSourceCollector(root: root, excluding: config?.exclude ?? [])
        .collect(paths: paths.isEmpty ? ["."] : paths)
      return .loaded(
        Loaded(
          config: config, sources: collected.map { SourceInput(path: $0.path, text: $0.text) },
          scopes: scopes))
    } catch {
      return .failed(.blocked(reason: "sources: \(error)"))
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

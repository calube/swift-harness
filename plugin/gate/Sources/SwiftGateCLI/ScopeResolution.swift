import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateRules

/// How a check learned which module each file belongs to.
struct ResolvedScopes: Sendable {
  let resolver: any ModuleScopeResolving
  /// `nil` when there is no `.swiftgate.toml` to name the packages.
  let graph: ModuleGraph?
  /// Non-gating findings that explain a degraded resolution; checks append them to their own.
  let notices: [Finding]

  static let fallbackRuleID = "swiftgate.scopes-fallback"

  /// Path conventions (`Sources/<Module>`, `Tests/<Module>`, name suffixes), for repositories
  /// without a config. They cannot see client interfaces or T2 test targets, so the output says so.
  static var pathConvention: ResolvedScopes {
    // The finding's fields are static and non-empty, so construction cannot violate the contract.
    let notice = try? Finding(
      ruleID: fallbackRuleID, severity: .nit, file: ConfigLoader.fileName, line: nil,
      message:
        "no \(ConfigLoader.fileName): module roles guessed from Sources/<Module> and "
        + "Tests/<Module> naming; client interfaces and T2 test targets are not recognised",
      failureScenario: nil)
    return ResolvedScopes(
      resolver: PathConventionModuleScopes(), graph: nil, notices: notice.map { [$0] } ?? [])
  }

  static func graph(_ graph: ModuleGraph) -> ResolvedScopes {
    ResolvedScopes(resolver: graph, graph: graph, notices: [])
  }

  func appendingNotices(to outcome: StaticCheckOutcome) -> StaticCheckOutcome {
    guard case .checked(let result) = outcome, !notices.isEmpty else { return outcome }
    return .checked(
      RuleRunResult(findings: result.findings + notices, allowances: result.allowances))
  }
}

enum ScopeResolution {
  enum Result: Sendable {
    case resolved(ResolvedScopes)
    case failed(StaticCheckOutcome)
  }

  /// The module graph from the config's `packages`, or path conventions when there is no config.
  static func resolve(config: Config?, root: URL, swiftPM: any SwiftPM) async -> Result {
    guard let config else { return .resolved(.pathConvention) }
    do throws(ModuleGraphLoadError) {
      let graph = try await ModuleGraphLoader(swiftPM: swiftPM, root: root).load(config: config)
      return .resolved(.graph(graph))
    } catch {
      switch error.verdict {
      case .red: return .failed(.invalid(reason: error.description))
      case .blocked, .green: return .failed(.blocked(reason: error.description))
      }
    }
  }

  /// The live SwiftPM for a repository root, with the root spelled the way `describe` reports
  /// paths, and manifest answers cached under the project.
  static func liveSwiftPM(root: URL) -> any SwiftPM {
    LiveSwiftPM(
      runner: LiveProcessRunner(), repositoryRoot: CanonicalPath.of(root),
      manifestCache: StateRootResolver.resolve(worktree: root).url(
        RunLayout.manifestCacheDirectory, directoryHint: .isDirectory),
      cacheEvents: .live(root: root))
  }
}

extension CacheEventRecorder {
  /// The project's writer, looked up at each record so a hook that never asks a cache never
  /// reads the config: nothing for a root with no loadable `.swiftgate.toml`, and a writer that
  /// keeps nothing under `[telemetry] enabled = false`.
  static func live(root: URL) -> CacheEventRecorder {
    CacheEventRecorder(events: {
      guard case .success(let config?) = StaticCheckInputs.loadConfig(root: root) else {
        return nil
      }
      return EventWriterFactory.make(root: root, enabled: config.telemetry.enabled)
    })
  }
}

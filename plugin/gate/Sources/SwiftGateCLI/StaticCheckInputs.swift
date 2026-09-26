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
    /// Ledger/claim/doc ids to reject in comments and test names (spec §5.1). Empty when the
    /// caller passed no `git` to `load` — callers that don't need the id-leak rules never pay for
    /// gathering them.
    let knownIds: Set<String>
    /// Sources that feed `knownIds` but could not be read (a corrupt ledger, claims file, or doc);
    /// the caller turns these into non-gating findings so a narrowed feed is visible.
    let unreadableIdSources: [KnownIdSources.UnreadableSource]
  }

  case loaded(Loaded)
  case failed(StaticCheckOutcome)

  /// An empty `paths` means the whole repository, minus the config's `exclude` directories.
  /// - Parameter git: when non-nil, ``KnownIdSources`` reads the known-id feed through it; omit it
  ///   for a check that doesn't run the id-leak rules.
  static func load(root: URL, paths: [String], swiftPM: any SwiftPM, git: (any Git)? = nil)
    async -> StaticCheckInputs
  {
    let config: Config?
    switch loadConfig(root: root) {
    case .success(let loaded): config = loaded
    case .failure(let failure): return .failed(failure.outcome)
    }
    switch await ScopeResolution.resolve(config: config, root: root, swiftPM: swiftPM) {
    case .failed(let outcome): return .failed(outcome)
    case .resolved(let scopes):
      let knownIds: KnownIdSources.Loaded
      if let git {
        knownIds = await KnownIdSources.load(root: root, git: git)
      } else {
        knownIds = KnownIdSources.Loaded(ids: [], unreadable: [])
      }
      return collect(
        root: root, paths: paths, config: config, scopes: scopes, knownIds: knownIds.ids,
        unreadableIdSources: knownIds.unreadable)
    }
  }

  /// Reads the sources for an already-resolved config and scopes, so several checks in one run
  /// describe the packages once.
  static func collect(
    root: URL, paths: [String], config: Config?, scopes: ResolvedScopes,
    knownIds: Set<String> = [], unreadableIdSources: [KnownIdSources.UnreadableSource] = []
  )
    -> StaticCheckInputs
  {
    do throws(SourceCollectionError) {
      let collected = try SwiftSourceCollector(root: root, excluding: config?.exclude ?? [])
        .collect(paths: paths.isEmpty ? ["."] : paths)
      return .loaded(
        Loaded(
          config: config, sources: collected.map { SourceInput(path: $0.path, text: $0.text) },
          scopes: scopes, knownIds: knownIds, unreadableIdSources: unreadableIdSources))
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

/// Turns a ``KnownIdSources/UnreadableSource`` list into findings `comments`, `testlint` and the
/// commit-message check all append the same way: never gating (a corrupt id source is the gate's
/// own hygiene, not a code defect to fail the build over), but never silent either.
enum KnownIdSourceFindings {
  static let ruleID = "comments.id-source-unreadable"

  static func make(_ unreadable: [KnownIdSources.UnreadableSource]) -> [Finding] {
    unreadable.compactMap { source in
      try? Finding(
        ruleID: ruleID, severity: .minor, file: source.path, line: nil,
        message: "known-id source could not be read: \(source.reason)", failureScenario: nil)
    }
  }

  /// No-op when `unreadable` is empty or the outcome never reached a checked state (`blocked`
  /// findings already explain themselves).
  static func appending(
    _ unreadable: [KnownIdSources.UnreadableSource], to outcome: StaticCheckOutcome
  )
    -> StaticCheckOutcome
  {
    guard case .checked(let result) = outcome, !unreadable.isEmpty else { return outcome }
    return .checked(
      RuleRunResult(findings: result.findings + make(unreadable), allowances: result.allowances))
  }
}

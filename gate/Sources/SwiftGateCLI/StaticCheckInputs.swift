import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateRules

/// What a path-based T0 check reads before running rules: the repository config (absent is
/// allowed) and the Swift files under the requested paths.
enum StaticCheckInputs {
  case loaded(config: Config?, sources: [SourceInput])
  case failed(StaticCheckOutcome)

  /// An empty `paths` means the whole repository.
  static func load(root: URL, paths: [String]) -> StaticCheckInputs {
    let config: Config?
    do throws(ConfigLoadError) {
      config = try ConfigLoader().load(repositoryRoot: root)
    } catch {
      switch error.verdict {
      case .red: return .failed(.invalid(reason: error.description))
      case .blocked, .green: return .failed(.blocked(reason: error.description))
      }
    }
    do throws(SourceCollectionError) {
      let collected = try SwiftSourceCollector(root: root).collect(
        paths: paths.isEmpty ? ["."] : paths)
      return .loaded(
        config: config, sources: collected.map { SourceInput(path: $0.path, text: $0.text) })
    } catch {
      return .failed(.blocked(reason: "sources: \(error)"))
    }
  }
}

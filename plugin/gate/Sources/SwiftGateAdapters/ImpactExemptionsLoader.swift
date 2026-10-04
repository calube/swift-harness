import Foundation
import SwiftGateDomain

public enum ImpactExemptionsLoadError: Error, Sendable, Equatable, CustomStringConvertible {
  case invalid(ImpactExemptionsError)
  case unreadable(String)

  /// An invalid file is the repository's own input (`red`); an unreadable one is the environment.
  public var verdict: Verdict {
    switch self {
    case .invalid: .red
    case .unreadable: .blocked
    }
  }

  public var description: String {
    switch self {
    case .invalid(let error): error.description
    case .unreadable(let reason): "\(ImpactExemptions.displayPath) is unreadable: \(reason)"
    }
  }
}

/// Reads `impact-exemptions.json` under a repository root's state root. A missing file means no
/// exemptions.
public struct ImpactExemptionsLoader: Sendable {
  public let root: URL

  public init(root: URL) {
    self.root = root
  }

  public func load() throws(ImpactExemptionsLoadError) -> ImpactExemptions {
    let url = StateRootResolver.resolve(worktree: root).url(RunLayout.impactExemptionsFile)
    guard FileManager.default.fileExists(atPath: url.path) else { return .none }
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw .unreadable(error.localizedDescription)
    }
    do throws(ImpactExemptionsError) {
      return try ImpactExemptions.decode(data)
    } catch {
      throw .invalid(error)
    }
  }
}

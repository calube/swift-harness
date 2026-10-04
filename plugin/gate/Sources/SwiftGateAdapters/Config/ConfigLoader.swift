import Foundation
import SwiftGateDomain

/// Reads `.swiftgate.toml` from a repository root.
public struct ConfigLoader: Sendable {
  public static let fileName = Config.fileName

  private let decoder: any ConfigDecoding

  public init(decoder: any ConfigDecoding = TOMLConfigDecoder()) {
    self.decoder = decoder
  }

  /// Returns `nil` when the repository has no config: swift-harness is not enabled there, and
  /// hooks must be no-ops.
  public func load(repositoryRoot: URL) throws(ConfigLoadError) -> Config? {
    let file = repositoryRoot.appending(path: Self.fileName, directoryHint: .notDirectory)
    let data: Data
    do {
      data = try Data(contentsOf: file)
    } catch CocoaError.fileReadNoSuchFile {
      return nil
    } catch {
      throw .unreadable(path: file.path, reason: error.localizedDescription)
    }
    guard let text = String(data: data, encoding: .utf8) else {
      throw .unreadable(path: file.path, reason: "not valid UTF-8")
    }
    return try decoder.decode(text)
  }
}

/// The config a clone runs under: a committed `.swiftgate.toml`, or the brownfield profile's
/// `config.toml` under the git common dir.
public enum LoadedConfig: Sendable, Equatable {
  case owned(Config)
  case brownfield(BrownfieldConfig)
}

public enum ProfileLoadError: Error, Sendable, Equatable, CustomStringConvertible {
  /// Both configs exist, so the clone's profile is ambiguous.
  case conflict(committed: String, common: String)
  /// The committed `.swiftgate.toml` failed to load.
  case config(ConfigLoadError)
  /// The common dir's `config.toml` at `path` failed to load.
  case brownfield(path: String, ConfigLoadError)

  public var verdict: Verdict {
    switch self {
    case .conflict: .red
    case .config(let error), .brownfield(_, let error): error.verdict
    }
  }

  public var description: String {
    switch self {
    case .conflict(let committed, let common):
      "\(committed) and \(common) both exist; a clone runs 1 profile, so delete one"
    case .config(let error): error.description
    case .brownfield(let path, .syntax(let line, let column, let message)):
      "\(path):\(line):\(column): \(message)"
    case .brownfield(let path, .invalid(let error)):
      error.issues.map { "\(path): \($0)" }.joined(separator: "\n")
    case .brownfield(_, let error): error.description
    }
  }
}

extension ConfigLoader {
  /// Reads the committed `.swiftgate.toml` at `repositoryRoot` and the brownfield config under
  /// `commonDir`. `nil` when neither exists.
  public func loadProfile(repositoryRoot: URL, commonDir: URL) throws(ProfileLoadError)
    -> LoadedConfig?
  {
    do {
      return try load(repositoryRoot: repositoryRoot).map(LoadedConfig.owned)
    } catch {
      throw .config(error)
    }
  }

  /// The git common dir of the worktree at or above `directory`, from git's own pointer files;
  /// `nil` outside a git worktree.
  public static func commonDirectory(enclosing directory: URL) -> URL? { nil }
}

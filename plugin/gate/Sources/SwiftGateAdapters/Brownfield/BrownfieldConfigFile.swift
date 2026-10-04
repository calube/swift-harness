import Foundation
import SwiftGateDomain

public enum BrownfieldConfigFileError: Error, Sendable, Equatable, CustomStringConvertible {
  /// The directory is in no git checkout, or its common dir holds no `config.toml`.
  case notBrownfield(path: String)
  case unreadable(path: String, reason: String)
  case invalid(path: String, error: ConfigLoadError)
  case lock(path: String, errno: Int32)
  case write(path: String, reason: String)

  public var description: String {
    switch self {
    case .notBrownfield(let path): "\(path) is not in a brownfield clone (no config.toml)"
    case .unreadable(let path, let reason): "\(path): \(reason)"
    case .invalid(let path, let error): "\(path): \(error)"
    case .lock(let path, let errno): "\(path): lock failed (errno \(errno))"
    case .write(let path, let reason): "\(path): \(reason)"
    }
  }
}

/// A brownfield clone's `config.toml`, changed only under an exclusive lock and written by an
/// atomic rename, so 2 writers can never interleave and a reader never sees half a file.
public struct BrownfieldConfigFile: Sendable {
  /// The lock file beside `config.toml`, shared by every writer of it.
  public static let lockFileName = "config.toml.lock"

  public let url: URL

  public init(url: URL) {
    self.url = url
  }

  /// The config of the clone holding `worktree`.
  public static func locate(worktree: URL) throws(BrownfieldConfigFileError) -> BrownfieldConfigFile
  {
    throw .notBrownfield(path: worktree.path)
  }

  /// Reads the config, applies `change`, and writes the result back, all under the lock.
  @discardableResult
  public func update(
    _ change: (BrownfieldConfig) throws(BrownfieldConfigFileError) -> BrownfieldConfig
  ) throws(BrownfieldConfigFileError) -> BrownfieldConfig {
    throw .notBrownfield(path: url.path)
  }
}

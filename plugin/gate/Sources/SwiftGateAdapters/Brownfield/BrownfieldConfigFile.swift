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
    guard let gitDir = StateRootResolver.gitDirectory(enclosing: worktree) else {
      throw .notBrownfield(path: worktree.path)
    }
    let url = StateRootResolver.commonDirectory(of: gitDir)
      .appending(path: StateRootResolver.commonConfigFile)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw .notBrownfield(path: worktree.path)
    }
    return BrownfieldConfigFile(url: url)
  }

  /// Reads the config, applies `change`, and writes the result back, all under the lock.
  @discardableResult
  public func update(
    _ change: (BrownfieldConfig) throws(BrownfieldConfigFileError) -> BrownfieldConfig
  ) throws(BrownfieldConfigFileError) -> BrownfieldConfig {
    let lockPath = url.deletingLastPathComponent().appending(path: Self.lockFileName).path
    let descriptor = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
    guard descriptor >= 0 else { throw .lock(path: lockPath, errno: errno) }
    defer { close(descriptor) }
    while flock(descriptor, LOCK_EX) != 0 {
      guard errno == EINTR else { throw .lock(path: lockPath, errno: errno) }
    }
    defer { flock(descriptor, LOCK_UN) }

    let text: String
    do {
      text = try String(contentsOf: url, encoding: .utf8)
    } catch {
      throw .unreadable(path: url.path, reason: error.localizedDescription)
    }
    let current: BrownfieldConfig
    do {
      current = try TOMLConfigDecoder().decodeBrownfield(text)
    } catch {
      throw .invalid(path: url.path, error: error)
    }
    let updated = try change(current)
    let temporary = url.deletingLastPathComponent()
      .appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    do {
      try Data(BrownfieldConfigTOML.render(updated).utf8).write(to: temporary)
      guard rename(temporary.path, url.path) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw .write(path: url.path, reason: error.localizedDescription)
    }
    return updated
  }
}

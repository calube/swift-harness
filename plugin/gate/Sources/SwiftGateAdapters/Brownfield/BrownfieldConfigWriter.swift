import Foundation
import SwiftGateDomain

/// Every case means nothing was written.
public enum BrownfieldConfigWriteError: Error, Sendable, Equatable {
  case lock(FileLockError)
  /// An existing state file failed to decode; a write over it would lose what it holds.
  case malformed(path: String, reason: String)
  /// The rendered config failed its own schema.
  case invalidRender(reason: String)
  case io(operation: String, path: String, reason: String)
  /// The change refused the state it was handed.
  case rejected(String)

  public var message: String {
    switch self {
    case .lock(let error): "could not take the config lock: \(error)"
    case .malformed(let path, let reason):
      "\(path) is unreadable, so nothing was written: \(reason)"
    case .invalidRender(let reason): "the config to write fails its schema: \(reason)"
    case .io(let operation, let path, let reason): "\(operation) \(path): \(reason)"
    case .rejected(let reason): reason
    }
  }
}

/// What 1 locked change writes: the config, and other state files beside it.
public struct BrownfieldStateWrite: Sendable {
  public let config: BrownfieldConfig
  /// Absolute paths under the clone's state root, each written by an atomic rename.
  public let files: [URL: Data]

  public init(config: BrownfieldConfig, files: [URL: Data] = [:]) {
    self.config = config
    self.files = files
  }
}

/// The only writer of `<common>/swift-harness/config.toml`. `discover --apply` and
/// `swiftgate allow` both go through it: 1 lock for the clone, a read of the current state under
/// it, and atomic renames, with `config.toml` written last.
public struct BrownfieldConfigWriter: Sendable {
  public static let lockName = "config.lock"

  public let layout: BrownfieldStateLayout
  private let lock: any CountingLock
  private let timeout: Duration

  public init(
    layout: BrownfieldStateLayout, lock: (any CountingLock)? = nil,
    timeout: Duration = .seconds(30)
  ) {
    self.layout = layout
    self.lock =
      lock ?? FileCountingLock(directory: layout.cloneRoot, name: Self.lockName, capacity: 1)
    self.timeout = timeout
  }

  /// Under the lock, hands `change` the current config and last discover record (`nil` when
  /// absent), then writes what it returns.
  @discardableResult
  public func update(
    _ change: (BrownfieldConfig?, DiscoverRecord?) throws(BrownfieldConfigWriteError) ->
      BrownfieldStateWrite
  ) async throws(BrownfieldConfigWriteError) -> BrownfieldConfig {
    throw .rejected("not written")
  }

  /// ``update(_:)`` for a change to the config alone, such as a new `[[allow]]` entry.
  @discardableResult
  public func updateConfig(
    _ transform: (BrownfieldConfig?) throws(BrownfieldConfigWriteError) -> BrownfieldConfig
  ) async throws(BrownfieldConfigWriteError) -> BrownfieldConfig {
    try await update { config, _ throws(BrownfieldConfigWriteError) in
      BrownfieldStateWrite(config: try transform(config))
    }
  }
}

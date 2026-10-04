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
    try makeDirectory(layout.cloneRoot)
    let lease: LockLease
    do {
      lease = try await lock.acquire(timeout: timeout)
    } catch {
      throw .lock(error)
    }
    defer { lease.release() }

    let write = try change(try readConfig(), try readLastDiscover())
    let text = BrownfieldConfigTOML.render(write.config)
    do {
      _ = try TOMLConfigDecoder().decodeBrownfield(text)
    } catch {
      throw .invalidRender(reason: error.description)
    }
    for (url, data) in write.files.sorted(by: { $0.key.path < $1.key.path }) {
      try store(data, at: url)
    }
    try store(Data(text.utf8), at: layout.config)
    return write.config
  }

  /// The applied config; `nil` before the first `discover --apply`.
  public func readConfig() throws(BrownfieldConfigWriteError) -> BrownfieldConfig? {
    guard let data = try contents(of: layout.config) else { return nil }
    do {
      return try TOMLConfigDecoder().decodeBrownfield(String(decoding: data, as: UTF8.self))
    } catch {
      throw .malformed(path: layout.config.path, reason: error.description)
    }
  }

  /// `discover/last.json`; `nil` before the first `discover --apply`.
  public func readLastDiscover() throws(BrownfieldConfigWriteError) -> DiscoverRecord? {
    guard let data = try contents(of: layout.discoverLast) else { return nil }
    do {
      return try JSONDecoder().decode(DiscoverRecord.self, from: data)
    } catch {
      throw .malformed(path: layout.discoverLast.path, reason: String(describing: error))
    }
  }

  private func contents(of url: URL) throws(BrownfieldConfigWriteError) -> Data? {
    do {
      return try Data(contentsOf: url)
    } catch CocoaError.fileReadNoSuchFile {
      return nil
    } catch {
      throw .io(operation: "read", path: url.path, reason: error.localizedDescription)
    }
  }

  private func makeDirectory(_ url: URL) throws(BrownfieldConfigWriteError) {
    do {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    } catch {
      throw .io(operation: "mkdir", path: url.path, reason: error.localizedDescription)
    }
  }

  /// `.atomic` writes a sibling temporary file and renames it over `url`, so a reader sees the old
  /// file or the new one, never part of either.
  private func store(_ data: Data, at url: URL) throws(BrownfieldConfigWriteError) {
    try makeDirectory(url.deletingLastPathComponent())
    do {
      try data.write(to: url, options: .atomic)
    } catch {
      throw .io(operation: "write", path: url.path, reason: error.localizedDescription)
    }
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

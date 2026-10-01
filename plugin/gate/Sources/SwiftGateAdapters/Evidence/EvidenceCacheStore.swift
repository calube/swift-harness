import Foundation
import SwiftGateDomain

/// Every write case means the cache file on disk is exactly what it was before the call.
public enum EvidenceCacheStoreError: Error, Sendable, Equatable {
  case lock(FileLockError)
  case io(operation: String, path: String, reason: String)
  case invalidBucket(EvidenceCacheLayoutError)
  /// A checker verdict is keyed by the quote's hash, so a claim without a quote has no key.
  case missingQuote(claimID: String)
  /// Only a live (recorded, not tombstoned) entry can be reused.
  case notCached(EvidenceFingerprint)
}

public enum EvidenceCacheWrite: Sendable, Equatable {
  case appended
  /// Entries are immutable once written; the first one for a fingerprint stands.
  case alreadyCached
  case tombstoned(EvidenceCacheTombstoneReason)
}

/// The user-level evidence reuse cache (spec §8.6) under an injected home directory.
///
/// Each write is a read-modify-write of one cache file under a one-slot ``FileCountingLock``
/// shared by every process on the machine. The new file is the old bytes, untouched, plus one
/// line, and replaces the old one by atomic rename, so a reader never sees a torn line and a line
/// that fails to decode is carried forward for ``EvidenceCacheContents/findings`` to report
/// rather than lost. Reads take no lock.
public struct EvidenceCacheStore: Sendable {
  public static let lockName = "evidence-cache.lock"

  public let layout: EvidenceCacheLayout
  private let lock: any CountingLock
  private let timeout: Duration
  private var events: CacheEventRecorder? = nil

  /// - Parameters:
  ///   - home: the directory standing in for `~`; the cache lives at
  ///     `<home>/.swift-harness/evidence-cache`.
  ///   - lock: defaults to a capacity-1 ``FileCountingLock`` in the cache root.
  ///   - events: records each store, reuse and tombstone; `nil` records none.
  public init(
    home: URL, lock: (any CountingLock)? = nil, timeout: Duration = .seconds(30),
    events: CacheEventRecorder? = nil
  ) {
    let layout = EvidenceCacheLayout(home: home.path)
    self.layout = layout
    self.lock =
      lock
      ?? FileCountingLock(
        directory: URL(filePath: layout.root, directoryHint: .isDirectory), name: Self.lockName,
        capacity: 1)
    self.timeout = timeout
  }

  @discardableResult
  public func record(_ claim: ReusableClaim, origin: EvidenceCacheOrigin)
    async throws(EvidenceCacheStoreError) -> EvidenceCacheWrite
  {
    try await append(to: claim.bucket) { contents in
      if let reason = contents.tombstones[claim.fingerprint] { return .skip(.tombstoned(reason)) }
      if contents.claim(claim.fingerprint) != nil { return .skip(.alreadyCached) }
      return .append(.claim(claim, origin: origin))
    }
  }

  @discardableResult
  public func recordVerdict(
    _ verdict: EvidenceCacheVerdict, for claim: ReusableClaim, origin: EvidenceCacheOrigin
  ) async throws(EvidenceCacheStoreError) -> EvidenceCacheWrite {
    let fingerprint = claim.fingerprint
    guard fingerprint.quoteHash != nil else { throw .missingQuote(claimID: claim.claim.id) }
    return try await append(to: .verdicts) { contents in
      if let reason = contents.tombstones[fingerprint] { return .skip(.tombstoned(reason)) }
      if contents.verdicts[fingerprint] != nil { return .skip(.alreadyCached) }
      return .append(.verdict(fingerprint, verdict: verdict, origin: origin))
    }
  }

  public func markReused(_ claim: ReusableClaim) async throws(EvidenceCacheStoreError) {
    let fingerprint = claim.fingerprint
    try await markReused(fingerprint, in: claim.bucket) { $0.claim(fingerprint) != nil }
  }

  public func markVerdictReused(_ fingerprint: EvidenceFingerprint)
    async throws(EvidenceCacheStoreError)
  {
    try await markReused(fingerprint, in: .verdicts) { $0.verdicts[fingerprint] != nil }
  }

  /// Hides the claim in its own pin's file. The same text and quote under another pin, and the
  /// checker's verdict on them, are separate facts and stay served.
  public func tombstone(_ claim: ReusableClaim, reason: EvidenceCacheTombstoneReason)
    async throws(EvidenceCacheStoreError)
  {
    try await append(to: claim.bucket) { contents in
      if let existing = contents.tombstones[claim.fingerprint] {
        return .skip(.tombstoned(existing))
      }
      return .append(.tombstone(claim.fingerprint, reason: reason))
    }
  }

  /// A missing file is an empty cache: nothing was ever recorded for that bucket.
  public func contents(of bucket: EvidenceCacheBucket) throws(EvidenceCacheStoreError)
    -> EvidenceCacheContents
  {
    let path = try file(bucket)
    return EvidenceCacheContents.decode(try read(path) ?? Data(), file: path)
  }

  private enum Decision {
    case append(EvidenceCacheRecord)
    case skip(EvidenceCacheWrite)
  }

  private func markReused(
    _ fingerprint: EvidenceFingerprint, in bucket: EvidenceCacheBucket,
    isLive: (EvidenceCacheContents) -> Bool
  ) async throws(EvidenceCacheStoreError) {
    var missing = false
    try await append(to: bucket) { contents in
      guard isLive(contents) else {
        missing = true
        return .skip(.alreadyCached)
      }
      return .append(.reuse(fingerprint))
    }
    if missing { throw .notCached(fingerprint) }
  }

  @discardableResult
  private func append(
    to bucket: EvidenceCacheBucket, _ decide: (EvidenceCacheContents) -> Decision
  ) async throws(EvidenceCacheStoreError) -> EvidenceCacheWrite {
    let path = try file(bucket)
    let lease: LockLease
    do {
      lease = try await lock.acquire(timeout: timeout)
    } catch {
      throw .lock(error)
    }
    defer { lease.release() }

    let existing = try read(path)
    let record: EvidenceCacheRecord
    switch decide(EvidenceCacheContents.decode(existing ?? Data(), file: path)) {
    case .skip(let outcome): return outcome
    case .append(let chosen): record = chosen
    }
    var data = existing ?? Data()
    if let last = data.last, last != UInt8(ascii: "\n") { data.append(UInt8(ascii: "\n")) }
    data.append(try Self.encodeLine(record, path: path))
    try write(data, to: path)
    return .appended
  }

  private func file(_ bucket: EvidenceCacheBucket) throws(EvidenceCacheStoreError) -> String {
    do {
      return try layout.file(bucket)
    } catch {
      throw .invalidBucket(error)
    }
  }

  private func read(_ path: String) throws(EvidenceCacheStoreError) -> Data? {
    do {
      return try Data(contentsOf: URL(filePath: path))
    } catch CocoaError.fileReadNoSuchFile {
      return nil
    } catch {
      throw .io(operation: "read", path: path, reason: error.localizedDescription)
    }
  }

  private func write(_ data: Data, to path: String) throws(EvidenceCacheStoreError) {
    let directory = URL(filePath: path).deletingLastPathComponent()
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      throw .io(operation: "mkdir", path: directory.path, reason: error.localizedDescription)
    }
    do {
      try data.write(to: URL(filePath: path), options: .atomic)
    } catch {
      throw .io(operation: "write", path: path, reason: error.localizedDescription)
    }
  }

  private static func encodeLine(_ record: EvidenceCacheRecord, path: String)
    throws(EvidenceCacheStoreError) -> Data
  {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    do {
      var line = try encoder.encode(record)
      line.append(UInt8(ascii: "\n"))
      return line
    } catch {
      throw .io(operation: "encode", path: path, reason: String(describing: error))
    }
  }
}

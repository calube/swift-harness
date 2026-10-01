import Foundation

/// An on-disk answer cache that records its lookups. The judge's cache is not one: its
/// `judge.call` already says whether it was cached.
public enum CacheName: String, Sendable, Codable, CaseIterable {
  /// SwiftPM's `describe` and `dump-package` answers, per package.
  case manifest
  /// The user-level evidence cache's reusable claims.
  case evidenceClaim = "evidence-claim"
  /// The user-level evidence cache's claim-checker verdicts.
  case evidenceVerdict = "evidence-verdict"
}

public enum CacheLookupOutcome: String, Sendable, Codable, CaseIterable {
  /// An answer was served from the cache.
  case hit
  /// The cache was asked and held no answer for the key.
  case miss
  /// A new answer was written under the key.
  case store
  /// An entry stopped being served.
  case tombstone
}

/// `cache.lookup`: 1 read or write of a cache. Hashes and closed values only: the command, the
/// package path, the claim's text and the cached answer never go in.
public struct CacheLookupEvent: Sendable, Equatable, Codable {
  public let cache: CacheName
  public let outcome: CacheLookupOutcome
  /// The SHA-256 the cache matches entries on. 1 key that stores 2 different ``answerHash``
  /// values over time missed an input.
  public let keyHash: String
  /// SHA-256 of the answer stored or served; `nil` for a miss or a tombstone.
  public let answerHash: String?
  /// Set on a tombstone only.
  public let tombstoneReason: EvidenceCacheTombstoneReason?

  public init(
    cache: CacheName, outcome: CacheLookupOutcome, keyHash: String, answerHash: String? = nil,
    tombstoneReason: EvidenceCacheTombstoneReason? = nil
  ) {
    self.cache = cache
    self.outcome = outcome
    self.keyHash = keyHash
    self.answerHash = answerHash
    self.tombstoneReason = tombstoneReason
  }
}

/// The hashes a `cache.lookup` carries, so every cache spells them the same way.
public enum CacheLookupHash {
  /// Lowercase hex SHA-256 of an answer's bytes.
  public static func answer(_ data: Data) -> String { "" }

  /// The hash of a cached claim as the cache serves it, so a hit can be matched to the store
  /// that wrote it. `nil` when the claim doesn't encode.
  public static func answer(claim: Claim) -> String? { nil }

  public static func answer(verdict: EvidenceCacheVerdict) -> String { "" }

  /// The evidence cache matches an entry on its file and the fingerprint's 2 digests; this is
  /// the SHA-256 of the 3 together, so the same fingerprint under 2 pins is 2 keys.
  public static func evidenceKey(bucket: EvidenceCacheBucket, fingerprint: EvidenceFingerprint)
    -> String
  { "" }
}

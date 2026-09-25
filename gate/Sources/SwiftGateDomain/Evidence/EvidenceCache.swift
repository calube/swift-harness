import CryptoKit
import Foundation

/// Which step of the design pipeline wrote a cache entry (spec §8.6: "entries carry `origin`").
public enum EvidenceCacheOrigin: String, Sendable, Equatable, Codable, CaseIterable {
  /// A research lane recorded the claim from a pinned package checkout or an SDK snapshot.
  case researchLane = "research-lane"
  /// The claim checker judged whether the quote says what the text says.
  case claimChecker = "claim-checker"
  /// `swiftgate probe` compiled the claim against the pinned SDK.
  case probe
}

/// The claim kinds the cache may hold. A codebase claim has no case here on purpose: the code
/// under it changes between commits, so a cached copy would go stale silently (spec §8.6).
public enum ReusableClaimKind: String, Sendable, Equatable, Codable, CaseIterable {
  /// A `file` citation into `.build/checkouts/<pkg>/…`, pinned `<pkg>@<version>`.
  case package
  /// A `snapshot` citation, pinned to the SDK version the doc was captured from.
  case snapshot
  /// A `probe` citation, pinned to the resolved pins and SDK the probe compiled against.
  case probe
}

/// Why an entry stops being served. Spec §8.6: "refutes and amends write tombstones".
public enum EvidenceCacheTombstoneReason: String, Sendable, Equatable, Codable, CaseIterable {
  case refuted
  case amended
}

/// A claim checker's judgment that the cache can hand to another repo asking the same question.
public enum EvidenceCacheVerdict: String, Sendable, Equatable, Codable, CaseIterable {
  case supported
  case refuted
}

/// Why a claim can't enter the cache. Every path into the cache goes through
/// ``ReusableClaim/init(_:)``, so these are the only ways a claim is kept out.
public enum EvidenceCacheRefusal: Error, Sendable, Equatable {
  /// A `file` citation into the repository itself rather than a pinned package checkout.
  case codebaseClaim(claimID: String)
  /// `capture` and `answer` citations belong to one design's run and mean nothing elsewhere.
  case notReusable(claimID: String, kind: Citation.Kind)
  case missingPin(claimID: String)
  /// The pin names the cache file, so it must be a single, non-empty path component.
  case invalidPin(claimID: String, pin: String)
}

/// SHA-256 hex digests of a claim's text and quote: the content address the cache matches on, so
/// the same question asked in another repo (different claim id, different line range) still hits.
public struct EvidenceFingerprint: Sendable, Hashable, Codable {
  public let textHash: String
  /// `nil` when the claim has no quote (a probe claim is verified by its verdict instead).
  public let quoteHash: String?

  public init(text: String, quote: String?) {
    self.textHash = Self.digest(text)
    self.quoteHash = quote.map(Self.digest)
  }

  public init(textHash: String, quoteHash: String?) {
    self.textHash = textHash
    self.quoteHash = quoteHash
  }

  static func digest(_ string: String) -> String {
    SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

/// A claim that may be cached. The only initialiser refuses every claim spec §8.6 excludes, so
/// no code path can put a codebase claim into the cache, and a cache line holding one fails to
/// decode.
public struct ReusableClaim: Sendable, Equatable {
  public let claim: Claim
  public let kind: ReusableClaimKind
  /// The pin that names the claim's cache file: `<pkg>@<version>` or the SDK version.
  public let pin: String

  public init(_ claim: Claim) throws(EvidenceCacheRefusal) {
    let citation = claim.citation
    guard let pin = citation.pin, !pin.isEmpty else {
      switch citation.kind {
      case .capture, .answer: throw .notReusable(claimID: claim.id, kind: citation.kind)
      case .file, .snapshot, .probe: throw .missingPin(claimID: claim.id)
      }
    }
    let kind: ReusableClaimKind
    switch citation.kind {
    case .file:
      guard Self.isPackageCitation(loc: citation.loc, pin: pin) else {
        throw .codebaseClaim(claimID: claim.id)
      }
      kind = .package
    case .snapshot: kind = .snapshot
    case .probe: kind = .probe
    case .capture, .answer: throw .notReusable(claimID: claim.id, kind: citation.kind)
    }
    guard EvidenceCacheLayout.isFileComponent(pin) else {
      throw .invalidPin(claimID: claim.id, pin: pin)
    }
    self.claim = claim
    self.kind = kind
    self.pin = pin
  }

  public var fingerprint: EvidenceFingerprint {
    EvidenceFingerprint(text: claim.text, quote: claim.citation.quote)
  }

  public var bucket: EvidenceCacheBucket {
    switch kind {
    case .package: .package(pin: pin)
    case .snapshot, .probe: .sdk(pin: pin)
    }
  }

  /// `.build/checkouts/<pkg>/…` pinned `<pkg>@<version>` with the same `<pkg>`. Anything else,
  /// including a `..` that climbs back out of the checkout, is the repository's own code.
  static func isPackageCitation(loc: String, pin: String) -> Bool {
    let prefix = ".build/checkouts/"
    guard loc.hasPrefix(prefix),
      !loc.split(separator: "/").contains(where: { $0 == ".." || $0 == "." })
    else { return false }
    let rest = loc.dropFirst(prefix.count)
    guard let slash = rest.firstIndex(of: "/") else { return false }
    let package = rest[..<slash]
    guard !package.isEmpty, let at = pin.firstIndex(of: "@") else { return false }
    return pin[..<at] == package && pin.index(after: at) < pin.endIndex
  }
}

/// One file of the cache.
public enum EvidenceCacheBucket: Sendable, Hashable {
  /// Package claims for one pin, `<pkg>@<version>.jsonl`, shared by every repo on that pin.
  case package(pin: String)
  /// Snapshot and probe claims for one SDK pin, `sdk/<pin>.jsonl`.
  case sdk(pin: String)
  /// Claim-checker verdicts, `verdicts.jsonl`, keyed by fingerprint alone.
  case verdicts
}

/// Paths under the cache root (`~/.swift-harness/evidence-cache/`, spec §4). Pure arithmetic; the
/// home directory is always passed in.
public struct EvidenceCacheLayout: Sendable, Equatable {
  public let root: String

  /// `<home>/.swift-harness/evidence-cache`.
  public init(home: String) {
    let base = home.hasSuffix("/") ? String(home.dropLast()) : home
    self.root = base + "/.swift-harness/evidence-cache"
  }

  /// The pin is re-checked here because a bucket can be built without a ``ReusableClaim``.
  public func file(_ bucket: EvidenceCacheBucket) throws(EvidenceCacheLayoutError) -> String {
    switch bucket {
    case .package(let pin):
      guard pin.contains("@"), Self.isFileComponent(pin) else { throw .invalidPin(pin) }
      return root + "/" + pin + ".jsonl"
    case .sdk(let pin):
      guard Self.isFileComponent(pin) else { throw .invalidPin(pin) }
      return root + "/sdk/" + pin + ".jsonl"
    case .verdicts:
      return root + "/verdicts.jsonl"
    }
  }

  static func isFileComponent(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".."
      && !name.contains(where: { $0 == "/" || $0 == "\0" || $0.isNewline })
  }
}

public enum EvidenceCacheLayoutError: Error, Sendable, Equatable {
  case invalidPin(String)
}

/// One line of a cache file. Files are append-only: a reuse or a tombstone is a new line about an
/// earlier entry, never an edit of it.
public enum EvidenceCacheRecord: Sendable, Equatable {
  case claim(ReusableClaim, origin: EvidenceCacheOrigin)
  case verdict(
    EvidenceFingerprint, verdict: EvidenceCacheVerdict, origin: EvidenceCacheOrigin)
  case reuse(EvidenceFingerprint)
  case tombstone(EvidenceFingerprint, reason: EvidenceCacheTombstoneReason)
}

extension EvidenceCacheRecord: Codable {
  private enum RecordType: String, Codable {
    case claim, verdict, reuse, tombstone
  }

  private enum CodingKeys: String, CodingKey {
    case type, claim, origin, verdict, reason, textHash, quoteHash
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch try c.decode(RecordType.self, forKey: .type) {
    case .claim:
      let claim = try c.decode(Claim.self, forKey: .claim)
      let reusable: ReusableClaim
      do {
        reusable = try ReusableClaim(claim)
      } catch {
        throw DecodingError.dataCorruptedError(
          forKey: .claim, in: c, debugDescription: "claim refused by the cache: \(error)")
      }
      self = .claim(reusable, origin: try c.decode(EvidenceCacheOrigin.self, forKey: .origin))
    case .verdict:
      let fingerprint = EvidenceFingerprint(
        textHash: try c.decode(String.self, forKey: .textHash),
        quoteHash: try c.decode(String.self, forKey: .quoteHash))
      self = .verdict(
        fingerprint, verdict: try c.decode(EvidenceCacheVerdict.self, forKey: .verdict),
        origin: try c.decode(EvidenceCacheOrigin.self, forKey: .origin))
    case .reuse:
      self = .reuse(try Self.fingerprint(c))
    case .tombstone:
      self = .tombstone(
        try Self.fingerprint(c),
        reason: try c.decode(EvidenceCacheTombstoneReason.self, forKey: .reason))
    }
  }

  private static func fingerprint(_ c: KeyedDecodingContainer<CodingKeys>) throws
    -> EvidenceFingerprint
  {
    EvidenceFingerprint(
      textHash: try c.decode(String.self, forKey: .textHash),
      quoteHash: try c.decodeIfPresent(String.self, forKey: .quoteHash))
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .claim(let claim, let origin):
      try c.encode(RecordType.claim, forKey: .type)
      try c.encode(claim.claim, forKey: .claim)
      try c.encode(origin, forKey: .origin)
    case .verdict(let fingerprint, let verdict, let origin):
      try c.encode(RecordType.verdict, forKey: .type)
      try c.encode(fingerprint.textHash, forKey: .textHash)
      try c.encode(fingerprint.quoteHash, forKey: .quoteHash)
      try c.encode(verdict, forKey: .verdict)
      try c.encode(origin, forKey: .origin)
    case .reuse(let fingerprint):
      try c.encode(RecordType.reuse, forKey: .type)
      try c.encode(fingerprint.textHash, forKey: .textHash)
      try c.encodeIfPresent(fingerprint.quoteHash, forKey: .quoteHash)
    case .tombstone(let fingerprint, let reason):
      try c.encode(RecordType.tombstone, forKey: .type)
      try c.encode(fingerprint.textHash, forKey: .textHash)
      try c.encodeIfPresent(fingerprint.quoteHash, forKey: .quoteHash)
      try c.encode(reason, forKey: .reason)
    }
  }
}

public struct CachedClaim: Sendable, Equatable {
  public let claim: ReusableClaim
  public let origin: EvidenceCacheOrigin
  public let reuseCount: Int

  public init(claim: ReusableClaim, origin: EvidenceCacheOrigin, reuseCount: Int) {
    self.claim = claim
    self.origin = origin
    self.reuseCount = reuseCount
  }
}

public struct CachedVerdict: Sendable, Equatable {
  public let verdict: EvidenceCacheVerdict
  public let origin: EvidenceCacheOrigin
  public let reuseCount: Int

  public init(verdict: EvidenceCacheVerdict, origin: EvidenceCacheOrigin, reuseCount: Int) {
    self.verdict = verdict
    self.origin = origin
    self.reuseCount = reuseCount
  }
}

/// What one cache file currently serves: live entries with their reuse counts, and a finding for
/// every line that failed to decode, so corruption is reported rather than quietly skipped.
public struct EvidenceCacheContents: Sendable, Equatable {
  public static let corruptLineRuleID = "evidence-cache.corrupt-line"

  public let claims: [CachedClaim]
  public let verdicts: [EvidenceFingerprint: CachedVerdict]
  public let tombstones: [EvidenceFingerprint: EvidenceCacheTombstoneReason]
  /// Non-gating (`minor`): a damaged cache costs a re-check, never a wrong answer.
  public let findings: [Finding]

  /// The first entry per fingerprint wins: entries are immutable once written. A tombstone hides
  /// its fingerprint wherever it sits in the file.
  public static func decode(_ data: Data, file: String) -> EvidenceCacheContents {
    let decoder = JSONDecoder()
    var records: [EvidenceCacheRecord] = []
    var findings: [Finding] = []
    let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
    for (offset, line) in lines.enumerated() where !line.isEmpty {
      do {
        records.append(try decoder.decode(EvidenceCacheRecord.self, from: Data(line)))
      } catch {
        let finding = try? Finding(
          ruleID: corruptLineRuleID, severity: .minor, file: file.isEmpty ? "." : file,
          line: offset + 1,
          message:
            "evidence cache line \(offset + 1) doesn't decode and is not served: \(error)",
          failureScenario: nil)
        if let finding { findings.append(finding) }
      }
    }
    return fold(records, findings: findings)
  }

  static func fold(_ records: [EvidenceCacheRecord], findings: [Finding]) -> EvidenceCacheContents {
    var claims: [(ReusableClaim, EvidenceCacheOrigin)] = []
    var seenClaims: Set<EvidenceFingerprint> = []
    var verdicts: [EvidenceFingerprint: (EvidenceCacheVerdict, EvidenceCacheOrigin)] = [:]
    var reuses: [EvidenceFingerprint: Int] = [:]
    var tombstones: [EvidenceFingerprint: EvidenceCacheTombstoneReason] = [:]
    for record in records {
      switch record {
      case .claim(let claim, let origin):
        if seenClaims.insert(claim.fingerprint).inserted { claims.append((claim, origin)) }
      case .verdict(let fingerprint, let verdict, let origin):
        if verdicts[fingerprint] == nil { verdicts[fingerprint] = (verdict, origin) }
      case .reuse(let fingerprint):
        reuses[fingerprint, default: 0] += 1
      case .tombstone(let fingerprint, let reason):
        if tombstones[fingerprint] == nil { tombstones[fingerprint] = reason }
      }
    }
    var liveVerdicts: [EvidenceFingerprint: CachedVerdict] = [:]
    for (fingerprint, entry) in verdicts where tombstones[fingerprint] == nil {
      liveVerdicts[fingerprint] = CachedVerdict(
        verdict: entry.0, origin: entry.1, reuseCount: reuses[fingerprint] ?? 0)
    }
    return EvidenceCacheContents(
      claims: claims.filter { tombstones[$0.0.fingerprint] == nil }.map {
        CachedClaim(claim: $0.0, origin: $0.1, reuseCount: reuses[$0.0.fingerprint] ?? 0)
      },
      verdicts: liveVerdicts,
      tombstones: tombstones, findings: findings)
  }

  public func claim(_ fingerprint: EvidenceFingerprint) -> CachedClaim? {
    claims.first { $0.claim.fingerprint == fingerprint }
  }

  public func verdict(text: String, quote: String) -> CachedVerdict? {
    verdicts[EvidenceFingerprint(text: text, quote: quote)]
  }
}

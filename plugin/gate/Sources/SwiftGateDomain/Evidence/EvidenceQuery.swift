/// `evidence find`'s pure search logic (spec §6.1, §8.6): whether a claim matches a free-text
/// query, optionally restricted to one package pin, and how a repo or cache claim becomes one
/// reported hit. No IO: the CLI reads `claims.jsonl` files and the reuse cache, this decides what
/// counts as a match.
public struct EvidenceQuery: Sendable, Equatable {
  /// A parsed `--pkg <name>@<version>`. Matching compares identity and version separately and
  /// requires both to be equal, so `tca@1.0.0` never matches `tca@1.0.1` or `tca@1.0` — a plain
  /// prefix or substring check on the raw pin string would let the shorter `tca@1.0` through.
  public struct PackagePin: Sendable, Equatable {
    public let identity: String
    public let version: String

    public init(identity: String, version: String) {
      self.identity = identity
      self.version = version
    }

    /// `nil` when `rawValue` has no `@` or either side is empty: not a value this type can
    /// represent, so the caller reports it as a malformed `--pkg` rather than a filter that
    /// silently matches nothing.
    public init?(rawValue: String) {
      guard let at = rawValue.firstIndex(of: "@") else { return nil }
      let identity = rawValue[..<at]
      let version = rawValue[rawValue.index(after: at)...]
      guard !identity.isEmpty, !version.isEmpty else { return nil }
      self.identity = String(identity)
      self.version = String(version)
    }

    func matches(pin: String) -> Bool {
      guard let candidate = PackagePin(rawValue: pin) else { return false }
      return candidate.identity == identity && candidate.version == version
    }
  }

  public let text: String
  public let pkg: PackagePin?

  public init(text: String, pkg: PackagePin?) {
    self.text = text
    self.pkg = pkg
  }

  /// Case-insensitive substring match over the claim's text and, when it has one, its citation's
  /// quote — the two places free text a user typed could plausibly appear. A `--pkg` filter is
  /// exact (identity and version both), never a prefix.
  public func matches(_ claim: Claim) -> Bool {
    if let pkg, !(claim.citation.pin.map(pkg.matches) ?? false) { return false }
    let needle = text.lowercased()
    if claim.text.lowercased().contains(needle) { return true }
    if let quote = claim.citation.quote, quote.lowercased().contains(needle) { return true }
    return false
  }
}

/// Which store a hit came from (spec §8.6): the repo's own `claims.jsonl` files, or the
/// user-level evidence reuse cache, tagged with the cache's own ``EvidenceCacheOrigin``. Closed
/// on purpose — a hit is always exactly one of these, never a third, unlabelled kind.
public enum EvidenceHitOrigin: Sendable, Equatable {
  case repo
  case cache(EvidenceCacheOrigin)

  /// A short, stable label for rendering: `"repo"`, or the cache origin's own raw value
  /// (`"research-lane"`, `"claim-checker"`, `"probe"`).
  public var label: String {
    switch self {
    case .repo: "repo"
    case .cache(let origin): origin.rawValue
    }
  }
}

/// One `evidence find` result (spec §6.1): a claim, wherever it was found, with enough of its
/// provenance to act on without re-reading the source.
public struct EvidenceFindHit: Sendable, Equatable {
  /// The claim's own id for a repo hit; a cache hit has no id from this repo, so it's the
  /// fingerprint's text hash instead — stable across repos, never a placeholder.
  public let id: String
  public let text: String
  public let status: Claim.Status
  public let origin: EvidenceHitOrigin
  /// How many times the cache has served this entry; `nil` for a repo claim, where reuse isn't
  /// tracked at all — never `0` standing in for "not applicable".
  public let reuseCount: Int?
  public let pin: String?
  /// Where the hit was read from: a repo-relative `claims.jsonl` path, or the cache bucket file's
  /// path.
  public let source: String

  public init(
    id: String, text: String, status: Claim.Status, origin: EvidenceHitOrigin,
    reuseCount: Int?, pin: String?, source: String
  ) {
    self.id = id
    self.text = text
    self.status = status
    self.origin = origin
    self.reuseCount = reuseCount
    self.pin = pin
    self.source = source
  }
}

public enum EvidenceFind {
  /// Every claim in one repo `claims.jsonl` that matches `query`, tagged `.repo` and carrying no
  /// reuse count.
  public static func repoHits(_ claims: [Claim], query: EvidenceQuery, source: String)
    -> [EvidenceFindHit]
  {
    claims.filter(query.matches).map { claim in
      EvidenceFindHit(
        id: claim.id, text: claim.text, status: claim.status, origin: .repo, reuseCount: nil,
        pin: claim.citation.pin, source: source)
    }
  }

  /// Every live (already tombstone-filtered by ``EvidenceCacheContents``) cache claim that
  /// matches `query`, tagged with the cache's recorded ``EvidenceCacheOrigin`` and reuse count.
  public static func cacheHits(_ claims: [CachedClaim], query: EvidenceQuery, source: String)
    -> [EvidenceFindHit]
  {
    claims.filter { query.matches($0.claim.claim) }.map { cached in
      EvidenceFindHit(
        id: cached.claim.fingerprint.textHash, text: cached.claim.claim.text,
        status: cached.claim.claim.status, origin: .cache(cached.origin),
        reuseCount: cached.reuseCount, pin: cached.claim.pin, source: source)
    }
  }

  /// Stable order independent of directory-enumeration or JSONL-append order: grouped by the
  /// file a hit came from, then by id within that file.
  public static func sorted(_ hits: [EvidenceFindHit]) -> [EvidenceFindHit] {
    hits.sorted {
      ($0.source, $0.id) < ($1.source, $1.id)
    }
  }
}

import Foundation

/// A citation backing a claim's text (spec §5.2). The five kinds carry the same shape; what
/// distinguishes them is which mechanical check `evidence check` runs against `loc`/`pin`:
/// `file` (quote is a substring of the cited lines; `pin` matches `Package.resolved`), `snapshot`
/// (quote is a substring of the stored doc snapshot), `capture` (`pin` is the stored output's
/// content hash), `probe` (the cited `swiftgate probe` file's verdict), `answer` (the cited answer
/// exists in the run's decision record).
public struct Citation: Sendable, Equatable, Codable {
  public enum Kind: String, Sendable, Equatable, Codable, CaseIterable {
    case file
    case snapshot
    case capture
    case probe
    case answer
  }

  public let kind: Kind
  /// Where the citation points: a repo/`.build/checkouts` path with a line range for `file`, a
  /// path under `snapshots/`, `captures/` or `probes/` for the other stored kinds, or a run id +
  /// question for `answer`.
  public let loc: String
  /// The version this citation is pinned to (commit sha, package version, SDK version, content
  /// hash). `nil` for `answer`, which has none.
  public let pin: String?
  /// The exact text the mechanical check looks for at `loc`. `nil` for kinds the checker verifies
  /// by other means (`probe`'s verdict, `answer`'s existence check).
  public let quote: String?

  public init(kind: Kind, loc: String, pin: String? = nil, quote: String? = nil) {
    self.kind = kind
    self.loc = loc
    self.pin = pin
    self.quote = quote
  }
}

/// One line of `<slug>.evidence/claims.jsonl` (spec §5.2): a fact the design relies on, tied to a
/// citation that grounds it and a status recording how much that grounding has been checked.
public struct Claim: Sendable, Equatable, Codable {
  /// The claim's place in the mechanical → judged → decayed pipeline (``ClaimStatusMachine``
  /// enforces which transitions are legal).
  public enum Status: String, Sendable, Equatable, Codable, CaseIterable {
    /// Just recorded; not yet mechanically checked.
    case new
    /// The mechanical check found the quote where the citation says it is.
    case quoteOk = "quote-ok"
    /// The mechanical check could not find the quote. Terminal except for decay to `stale`: a
    /// mechanical fail is not a judgment call the opus checker gets to override.
    case quoteFail = "quote-fail"
    /// The claim is trustworthy: judged from a `quote-ok` citation, or verified directly from a
    /// `probe` verdict.
    case supported
    /// The claim is false: judged from a `quote-ok` citation, or refuted directly by a `probe`.
    case refuted
    /// The citation no longer reflects the pinned source (spec §8.5); reachable from any status.
    case stale
  }

  /// Committed id, `ev-` + ≥3 words (spec §5.1; see ``IdPolicy``).
  public let id: String
  /// The research lane that produced this claim.
  public let lane: String
  public let text: String
  public let citation: Citation
  public let status: Status

  public init(id: String, lane: String, text: String, citation: Citation, status: Status) {
    self.id = id
    self.lane = lane
    self.text = text
    self.citation = citation
    self.status = status
  }
}

/// Legal status transitions for a claim (spec §5.2). Pure function of the *current* status, the
/// *proposed next* status, and the claim's citation kind — a probe claim's verdict stands in for
/// the mechanical quote check, so it skips straight from `new` to `supported`/`refuted`.
public enum ClaimStatusMachine {
  public static func canTransition(
    from current: Claim.Status, to next: Claim.Status, citationKind: Citation.Kind
  ) -> Bool {
    if next == .stale { return true }
    switch current {
    case .new:
      switch next {
      case .quoteOk, .quoteFail:
        return citationKind != .probe
      case .supported, .refuted:
        return citationKind == .probe
      case .new, .stale:
        return false
      }
    case .quoteOk:
      return next == .supported || next == .refuted
    case .quoteFail, .supported, .refuted, .stale:
      return false
    }
  }
}

/// JSON Lines encoding for claims: one compact, key-sorted object per claim, so two encodes of the
/// same value produce identical bytes (a design doc's evidence file is reviewed as a diff).
public enum ClaimJSON {
  public static func encodeLine(_ claim: Claim) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(claim)
    data.append(UInt8(ascii: "\n"))
    return data
  }

  /// Decodes every line. Lines that fail to parse (for example one torn by a crash mid-write) are
  /// counted rather than failing the whole file.
  public static func decode(_ data: Data) -> (claims: [Claim], invalidLines: Int) {
    let decoder = JSONDecoder()
    var claims: [Claim] = []
    var invalid = 0
    for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
      if let claim = try? decoder.decode(Claim.self, from: Data(line)) {
        claims.append(claim)
      } else {
        invalid += 1
      }
    }
    return (claims, invalid)
  }
}

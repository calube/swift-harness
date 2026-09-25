/// The committed id kinds spec §5.1 defines a prefix and word-count rule for. Task, wave and
/// amendment ids are local to the ledger and free-form, so this policy has nothing to check for
/// them — only ids that leave the ledger and land in committed docs, claims or amendments.
public enum IdKind: String, Sendable, Equatable, CaseIterable {
  case requirement = "req"
  case testPlanItem = "test"
  case claim = "ev"

  /// The commit-time prefix, including the trailing hyphen (`req-`, `test-`, `ev-`).
  public var prefix: String { rawValue + "-" }
}

/// Machine-key id forms (spec §5.1): "ids are machine keys, never reader words."
public enum IdPolicy {
  /// "≥3 words from its title."
  public static let minimumWords = 3

  /// Whether `id` is `<kind.prefix>` + at least ``minimumWords`` lowercase-kebab words, and not an
  /// `-R1`-style revision suffix — the per-revision namespacing spec §5.1 disallows outright,
  /// because ids are unique across the repo instead.
  public static func isValid(_ id: String, kind: IdKind) -> Bool {
    guard id.hasPrefix(kind.prefix) else { return false }
    let words = id.dropFirst(kind.prefix.count).split(
      separator: "-", omittingEmptySubsequences: false)
    guard words.count >= minimumWords, words.allSatisfy(isKebabWord) else { return false }
    guard let last = words.last, !isRevisionSuffix(last) else { return false }
    return true
  }

  /// A `NNNN-<title>` ADR filename (spec §5.1): a zero-padded 4-digit number, then ≥1 kebab word.
  public static func isValidADRSlug(_ slug: String) -> Bool {
    let parts = slug.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0].count == 4, parts[0].allSatisfy(\.isNumber) else {
      return false
    }
    let words = parts[1].split(separator: "-", omittingEmptySubsequences: false)
    return !words.isEmpty && words.allSatisfy(isKebabWord)
  }

  private static func isKebabWord(_ word: Substring) -> Bool {
    !word.isEmpty
      && word.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber) }
  }

  /// `r` followed by one or more digits (`r1`, `r12`) — the `<slug>-R1` pattern, case-folded.
  private static func isRevisionSuffix(_ word: Substring) -> Bool {
    guard word.first == "r" else { return false }
    let digits = word.dropFirst()
    return !digits.isEmpty && digits.allSatisfy(\.isNumber)
  }
}

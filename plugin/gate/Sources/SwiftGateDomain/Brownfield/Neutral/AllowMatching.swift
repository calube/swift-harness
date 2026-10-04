import Foundation

/// Matches a finding's line against `[[allow]]` entries. An entry names its line by the hash of the
/// line's text, so a moved line keeps its waiver and an edited one loses it.
public enum AllowMatching {
  public static let inlineMarker = "swiftgate:allow"

  /// Lowercase hex SHA-256 of the line with its surrounding whitespace trimmed, so re-indenting a
  /// line keeps its waiver.
  public static func lineSHA(_ text: String) -> String {
    CaptureDigest.sha256Hex(Data(text.trimmedWhitespace.utf8))
  }

  /// The entry that waives `rule` on a line of `path` holding `lineText`, if any.
  public static func entry(
    rule: BrownfieldRuleID, path: String, lineText: String, in allow: [BrownfieldAllow]
  ) -> BrownfieldAllow? {
    let sha = lineSHA(lineText)
    return allow.first { $0.rule == rule.rawValue && $0.path == path && $0.lineSHA == sha }
  }

  /// `swiftgate:allow <rule> — <reason>` in 1 comment segment: the rule id and the reason, or a
  /// `nil` reason for a bare allow. The separator is an em dash or `--`.
  static func inline(_ segment: String) -> (rule: String, reason: String?)? {
    guard segment.hasPrefix(inlineMarker) else { return nil }
    let rest = segment.dropFirst(inlineMarker.count)
    guard rest.first?.isWhitespace == true else { return nil }
    let afterSpace = rest.drop { $0.isWhitespace }
    let rule = afterSpace.prefix { !$0.isWhitespace }
    guard !rule.isEmpty else { return nil }
    var tail = afterSpace.dropFirst(rule.count).drop { $0.isWhitespace }
    if tail.hasPrefix("—") {
      tail = tail.dropFirst()
    } else if tail.hasPrefix("--") {
      tail = tail.dropFirst(2)
    } else {
      return (String(rule), nil)
    }
    let reason = tail.trimmedWhitespace
    return (String(rule), reason.isEmpty ? nil : reason)
  }
}

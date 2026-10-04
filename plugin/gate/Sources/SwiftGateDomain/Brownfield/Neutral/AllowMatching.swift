/// Matches a finding's line against `[[allow]]` entries. An entry names its line by the hash of the
/// line's text, so a moved line keeps its waiver and an edited one loses it.
public enum AllowMatching {
  /// Lowercase hex SHA-256 of the line with its surrounding whitespace trimmed, so re-indenting a
  /// line keeps its waiver.
  public static func lineSHA(_ text: String) -> String {
    ""
  }

  /// The entry that waives `rule` on a line of `path` holding `lineText`, if any.
  public static func entry(
    rule: BrownfieldRuleID, path: String, lineText: String, in allow: [BrownfieldAllow]
  ) -> BrownfieldAllow? {
    nil
  }
}

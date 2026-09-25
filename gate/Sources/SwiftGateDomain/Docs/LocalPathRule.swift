/// `docs-lint`'s local-paths family (spec D25): a path baked into prose that only resolves on the
/// machine that typed it — a home directory, `/Users/`, `/home/`, a temp directory, `$HOME` — reads
/// fine to its author and breaks for every other reader. Docs cite repo files by relative path
/// instead.
///
/// `scan` is pure text in, `Finding`s out: it carries no file identity of its own, because the
/// same detector is meant to run twice — once over an already-written doc (`DocsLintPolicy`, which
/// knows the doc's path) and once over the text of an edit that hasn't landed yet (a future
/// write-time hook, which knows the tool call's target path instead). Each caller rebuilds the
/// `Finding` with the path it actually has; the placeholder `file` this emits is never shown to a
/// reader.
public enum LocalPathRule {
  public static let ruleID = "docs-lint.local-path"

  /// Never surfaced: every caller replaces it with the path it knows before reporting a finding.
  static let unscopedFile = "(unscoped)"

  /// Prefixes that make a token a local, machine-specific path. `~/` is handled separately so it
  /// can be weighed against ``DocsLintPolicy/productPaths``.
  private static let flaggedPrefixes = [
    "$HOME/", "/Users/", "/home/", "/private/tmp/", "/var/folders/",
  ]

  public static func scan(_ text: String) -> [Finding] {
    var findings: [Finding] = []
    var fenceMarker: String?
    for (index, rawLine) in lines(of: text).enumerated() {
      let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
      if let marker = fenceMarker {
        if trimmed.hasPrefix(marker) { fenceMarker = nil }
        // A path quoted inside a fenced block — most often an example of what NOT to do — isn't a
        // live reference a reader will hit, so it never counts.
        continue
      }
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        fenceMarker = String(trimmed.prefix(3))
        continue
      }
      for token in tokens(in: rawLine) where isMachineSpecific(token) {
        // token and message are never empty, so the report contract cannot reject this.
        if let finding = try? Finding(
          ruleID: ruleID, severity: .major, file: unscopedFile, line: index + 1,
          message:
            "\"\(token)\" is a machine-specific path; use a repository-relative path (or one "
            + "of the harness's own allowlisted product paths).",
          failureScenario: nil)
        {
          findings.append(finding)
        }
      }
    }
    return findings
  }

  // MARK: - Line splitting

  private static func lines(of text: String) -> [String] {
    var lines: [String] = []
    var current = ""
    for character in text {
      if character == "\n" || character == "\r\n" {
        lines.append(current)
        current = ""
      } else {
        current.append(character)
      }
    }
    lines.append(current)
    if lines.last == "" { lines.removeLast() }
    return lines
  }

  // MARK: - Tokenising and matching

  /// Splits on anything that isn't part of a path or URL, so `[text](dest)`, quoted paths and
  /// trailing punctuation never glue onto the token that follows.
  private static func tokens(in line: String) -> [String] {
    var tokens: [String] = []
    var current = ""
    func flush() {
      if !current.isEmpty {
        tokens.append(current)
        current = ""
      }
    }
    for character in line {
      if character.isLetter || character.isNumber || "/.-_~$:".contains(character) {
        current.append(character)
      } else {
        flush()
      }
    }
    flush()
    return tokens
  }

  /// A URL that happens to carry `/Users/` in its path (`https://example.com/Users/x`) names a
  /// remote resource, not a local one, so any token containing a scheme separator is exempt
  /// entirely rather than pattern-matched.
  private static func isMachineSpecific(_ token: String) -> Bool {
    guard !token.contains("://") else { return false }
    if token.hasPrefix("~/") {
      return !DocsLintPolicy.productPaths.contains { token.hasPrefix($0) }
    }
    return flaggedPrefixes.contains { token.hasPrefix($0) }
  }
}

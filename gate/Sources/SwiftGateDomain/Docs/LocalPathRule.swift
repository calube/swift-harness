/// `docs-lint`'s local-paths family (spec D25): a path baked into prose that only resolves on the
/// machine that typed it — a home directory, `/Users/`, `/home/`, a temp directory, `$HOME` — reads
/// fine to its author and breaks for every other reader. Docs cite repo files by relative path
/// instead.
///
/// The spec is silent on whether a path inside a fenced code block or inline code span is exempt.
/// A path quoted as a "don't do this" example still breaks for every reader who copies it, so this
/// scanner flags fenced and inline code the same as prose — it never tracks fence state at all.
///
/// `scan` is pure text in, `Finding`s out, but takes the target `file` as a label: the same
/// detector runs twice — once over an already-written doc (`DocsLintPolicy`, which knows the doc's
/// path) and once over the text of an edit that hasn't landed yet (a future write-time hook, which
/// knows the tool call's target path instead) — and a caller that forgot to attribute the real path
/// would silently mislabel every finding it reports, so the label is part of the call, not
/// something every caller has to remember to rebuild.
public enum LocalPathRule {
  public static let ruleID = "docs-lint.local-path"

  /// Prefixes that make a token a local, machine-specific path. `~/` is handled separately so it
  /// can be weighed against ``DocsLintPolicy/productPaths``.
  private static let flaggedPrefixes = [
    "$HOME/", "/Users/", "/home/", "/private/tmp/", "/var/folders/",
  ]

  public static func scan(_ text: String, file: String) -> [Finding] {
    var findings: [Finding] = []
    for (index, rawLine) in lines(of: text).enumerated() {
      for token in tokens(in: rawLine) where isMachineSpecific(token) {
        // file, ruleID and message are never empty, so the report contract cannot reject this.
        if let finding = try? Finding(
          ruleID: ruleID, severity: .major, file: file, line: index + 1,
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

/// A token matched against a line's code, with its strings and comments blanked.
struct CodeToken: Sendable {
  /// What the finding message calls it.
  let name: String
}

/// Per-language escape hatches, lint suppressions, and skipped or focused tests.
enum UnsafeShortcutTable {
  static func codeTokens(for language: AreaLanguage, inTestFile: Bool) -> [CodeToken] {
    []
  }
}

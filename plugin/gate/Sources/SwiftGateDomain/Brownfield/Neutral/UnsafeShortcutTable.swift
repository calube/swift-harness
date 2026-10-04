/// A token matched against a line's code, with its strings and comments blanked.
struct CodeToken: Sendable {
  enum Tail: Sendable {
    /// Anything may follow.
    case any
    /// No identifier character follows.
    case wordEnd
    /// More identifier characters may follow and belong to the token (`XCTAssert` covers
    /// `XCTAssertEqual`).
    case identifier
  }

  /// What the finding message calls it.
  let name: String
  let literal: [Character]
  /// The character before is neither an identifier character nor `.`.
  let wordStart: Bool
  let tail: Tail
  /// What must come next, after optional whitespace.
  let then: [Character]?
  /// `then` ends a word.
  let thenWordEnd: Bool
  /// Only whitespace comes before it on the line.
  let lineStart: Bool
  /// Counts only in a test file: the spelling means something else in app code.
  let testFileOnly: Bool

  init(
    _ literal: String, name: String? = nil, wordStart: Bool = true, tail: Tail = .any,
    then: String? = nil, thenWordEnd: Bool = false, lineStart: Bool = false,
    testFileOnly: Bool = false
  ) {
    self.name = name ?? literal
    self.literal = Array(literal)
    self.wordStart = wordStart
    self.tail = tail
    self.then = then.map(Array.init)
    self.thenWordEnd = thenWordEnd
    self.lineStart = lineStart
    self.testFileOnly = testFileOnly
  }

  /// Where the token starts and where its tail ends, for each match within `range` of `code`.
  func matches(in code: [Character], within range: Range<Int>? = nil) -> [Range<Int>] {
    let bounds = range ?? 0..<code.count
    guard literal.count <= bounds.count else { return [] }
    var found: [Range<Int>] = []
    var start = bounds.lowerBound
    while start + literal.count <= bounds.upperBound {
      defer { start += 1 }
      guard Array(code[start..<(start + literal.count)]) == literal else { continue }
      if wordStart, start > 0, code[start - 1].isIdentifierCharacter || code[start - 1] == "." {
        continue
      }
      if lineStart, code[..<start].contains(where: { !$0.isWhitespace }) { continue }
      var end = start + literal.count
      switch tail {
      case .any: break
      case .wordEnd:
        if end < code.count, code[end].isIdentifierCharacter { continue }
      case .identifier:
        while end < code.count, code[end].isIdentifierCharacter { end += 1 }
      }
      if let then {
        var next = end
        while next < code.count, code[next].isWhitespace { next += 1 }
        guard next + then.count <= code.count, Array(code[next..<(next + then.count)]) == then
        else { continue }
        let after = next + then.count
        if thenWordEnd, after < code.count, code[after].isIdentifierCharacter { continue }
      }
      found.append(start..<end)
    }
    return found
  }
}

/// Per-language escape hatches, lint suppressions, and skipped or focused tests.
enum UnsafeShortcutTable {
  /// Tokens in code.
  static func codeTokens(for language: AreaLanguage, inTestFile: Bool) -> [CodeToken] {
    let tokens: [CodeToken]
    switch language {
    case .swift:
      tokens = [
        CodeToken("try!"), CodeToken("as!"),
        CodeToken("fatalError", tail: .wordEnd, then: "("),
        CodeToken(
          "@unchecked", name: "@unchecked Sendable", wordStart: false, tail: .wordEnd,
          then: "Sendable", thenWordEnd: true),
        CodeToken("nonisolated", name: "nonisolated(unsafe)", tail: .wordEnd, then: "(unsafe)"),
        CodeToken("XCTSkip", tail: .identifier, then: "("),
        CodeToken(".disabled", wordStart: false, tail: .wordEnd, then: "(", testFileOnly: true),
      ]
    case .kotlin:
      tokens = [
        CodeToken("!!", wordStart: false),
        CodeToken("@Suppress", wordStart: false, tail: .wordEnd),
        CodeToken("@file:Suppress", wordStart: false, tail: .wordEnd),
        CodeToken("@Ignore", wordStart: false, tail: .wordEnd),
        CodeToken("@Disabled", wordStart: false, tail: .identifier),
      ]
    case .java:
      tokens = [
        CodeToken("@SuppressWarnings", wordStart: false, tail: .wordEnd),
        CodeToken("@Ignore", wordStart: false, tail: .wordEnd),
        CodeToken("@Disabled", wordStart: false, tail: .identifier),
      ]
    case .javascript, .typescript:
      let focus = ["only", "skip"].map {
        CodeToken(".\($0)", wordStart: false, tail: .wordEnd, then: "(", testFileOnly: true)
      }
      let prefixed = ["xit", "xtest", "xdescribe", "fit", "fdescribe"].map {
        CodeToken($0, tail: .wordEnd, then: "(", testFileOnly: true)
      }
      let cast =
        language == .typescript
        ? [CodeToken("as", name: "as any", tail: .wordEnd, then: "any", thenWordEnd: true)] : []
      tokens = cast + focus + prefixed
    case .go:
      tokens = [
        CodeToken(".Skip", wordStart: false, tail: .identifier, then: "(", testFileOnly: true)
      ]
    case .rust:
      tokens = [
        CodeToken("#[allow", wordStart: false, tail: .wordEnd, then: "("),
        CodeToken("#![allow", wordStart: false, tail: .wordEnd, then: "("),
        CodeToken("#[expect", wordStart: false, tail: .wordEnd, then: "("),
        CodeToken("#[ignore", wordStart: false, tail: .wordEnd),
      ]
    case .python:
      tokens = [
        CodeToken("@pytest.mark.skip", wordStart: false, tail: .identifier),
        CodeToken("@unittest.skip", wordStart: false, tail: .identifier),
        CodeToken("pytest.skip", tail: .wordEnd, then: "("),
        CodeToken(".skipTest", wordStart: false, tail: .wordEnd, then: "(", testFileOnly: true),
      ]
    case .ruby:
      tokens = ["skip", "pending", "xit", "xdescribe", "xcontext", "fit", "fdescribe", "fcontext"]
        .map { CodeToken($0, tail: .wordEnd, lineStart: true, testFileOnly: true) }
    case .other:
      tokens = []
    }
    return tokens.filter { inTestFile || !$0.testFileOnly }
  }

  /// Lint suppressions, matched at the start of a comment's text or of any part of it after
  /// another comment marker (`# type: ignore # noqa`).
  static func commentDirectives(for language: AreaLanguage) -> [String] {
    switch language {
    case .swift: ["swiftlint:disable", "swiftformat:disable"]
    case .kotlin: ["ktlint-disable", "noinspection"]
    case .java: ["CHECKSTYLE:OFF", "CHECKSTYLE.OFF", "NOPMD", "NOSONAR", "noinspection"]
    case .javascript, .typescript:
      ["eslint-disable", "@ts-ignore", "@ts-expect-error", "@ts-nocheck", "biome-ignore"]
    case .go: ["nolint", "lint:ignore"]
    case .rust: []
    case .python: ["noqa", "type: ignore", "type:ignore", "pylint: disable", "pyright: ignore"]
    case .ruby: ["rubocop:disable", "rubocop:todo"]
    case .other: []
    }
  }
}

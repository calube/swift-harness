/// 1 source line split into its code and its comments. `code` has the same length as `raw`, with
/// every comment character and every character inside a string literal replaced by a space, so a
/// token match on `code` never lands in a string or comment and its index still points into `raw`.
struct LexedLine: Sendable {
  let number: Int
  let raw: [Character]
  let code: [Character]
  /// Each comment's text on this line, without its markers.
  let comments: [String]

  var codeString: String { String(code) }
}

/// Splits lines into code, strings and comments by quotes and comment markers alone. It is not a
/// parser: it knows each language's delimiters, escapes, raw and multi-line strings, and nested
/// block comments, which is all the token tables need.
struct NeutralLexer {
  struct Delimiter {
    let open: String
    let close: String
    let escapes: Bool
    let multiline: Bool
  }

  let lineComment: String?
  let blockComment: (open: String, close: String)?
  let nestedBlocks: Bool
  /// Longest opener first, so `"""` wins over `"`.
  let strings: [Delimiter]
  /// `'x'` is a character literal, and a `'` that doesn't close 1 character later is code, such
  /// as a Rust lifetime.
  let characterLiterals: Bool

  /// `nil` for a language the rules have no table for.
  init?(language: AreaLanguage) {
    let quote = Delimiter(open: "\"", close: "\"", escapes: true, multiline: false)
    let single = Delimiter(open: "'", close: "'", escapes: true, multiline: false)
    let tripleQuote = Delimiter(open: "\"\"\"", close: "\"\"\"", escapes: true, multiline: true)
    switch language {
    case .swift:
      self.init(
        lineComment: "//", blockComment: ("/*", "*/"), nestedBlocks: true,
        strings: [
          Delimiter(open: "#\"\"\"", close: "\"\"\"#", escapes: false, multiline: true),
          Delimiter(open: "#\"", close: "\"#", escapes: false, multiline: false),
          tripleQuote, quote,
        ], characterLiterals: false)
    case .kotlin:
      self.init(
        lineComment: "//", blockComment: ("/*", "*/"), nestedBlocks: true,
        strings: [
          Delimiter(open: "\"\"\"", close: "\"\"\"", escapes: false, multiline: true), quote,
        ], characterLiterals: true)
    case .java:
      self.init(
        lineComment: "//", blockComment: ("/*", "*/"), nestedBlocks: false,
        strings: [tripleQuote, quote], characterLiterals: true)
    case .javascript, .typescript:
      self.init(
        lineComment: "//", blockComment: ("/*", "*/"), nestedBlocks: false,
        strings: [Delimiter(open: "`", close: "`", escapes: true, multiline: true), quote, single],
        characterLiterals: false)
    case .go:
      self.init(
        lineComment: "//", blockComment: ("/*", "*/"), nestedBlocks: false,
        strings: [Delimiter(open: "`", close: "`", escapes: false, multiline: true), quote],
        characterLiterals: true)
    case .rust:
      self.init(
        lineComment: "//", blockComment: ("/*", "*/"), nestedBlocks: true,
        strings: [
          Delimiter(open: "r#\"", close: "\"#", escapes: false, multiline: true),
          Delimiter(open: "r\"", close: "\"", escapes: false, multiline: true),
          Delimiter(open: "\"", close: "\"", escapes: true, multiline: true),
        ], characterLiterals: true)
    case .python:
      self.init(
        lineComment: "#", blockComment: nil, nestedBlocks: false,
        strings: [
          tripleQuote, Delimiter(open: "'''", close: "'''", escapes: true, multiline: true),
          quote, single,
        ], characterLiterals: false)
    case .ruby:
      self.init(
        lineComment: "#", blockComment: nil, nestedBlocks: false,
        strings: [
          Delimiter(open: "\"", close: "\"", escapes: true, multiline: true),
          Delimiter(open: "'", close: "'", escapes: true, multiline: true),
        ], characterLiterals: false)
    case .other:
      return nil
    }
  }

  private init(
    lineComment: String?, blockComment: (open: String, close: String)?, nestedBlocks: Bool,
    strings: [Delimiter], characterLiterals: Bool
  ) {
    self.lineComment = lineComment
    self.blockComment = blockComment
    self.nestedBlocks = nestedBlocks
    self.strings = strings
    self.characterLiterals = characterLiterals
  }

  private enum State {
    case code
    case block(depth: Int)
    case string(Delimiter)
  }

  /// Lexes consecutive runs of lines; a jump in line numbers starts again in code, since what
  /// the unseen lines opened is unknown.
  func lex(_ lines: [NeutralSourceLine]) -> [LexedLine] {
    var state = State.code
    var previous: Int?
    var result: [LexedLine] = []
    for line in lines {
      if let previous, line.number != previous + 1 { state = .code }
      previous = line.number
      result.append(lexLine(line, state: &state))
    }
    return result
  }

  private func lexLine(_ line: NeutralSourceLine, state: inout State) -> LexedLine {
    let raw = Array(line.text)
    var code = raw
    var comments: [String] = []
    var comment: [Character] = []
    var index = 0

    func starts(_ token: String, at position: Int) -> Bool {
      let characters = Array(token)
      guard position + characters.count <= raw.count else { return false }
      return Array(raw[position..<(position + characters.count)]) == characters
    }
    func blank(_ range: Range<Int>) {
      for position in range where position < code.count { code[position] = " " }
    }

    while index < raw.count {
      switch state {
      case .code:
        if let marker = lineComment, starts(marker, at: index) {
          blank(index..<raw.count)
          comments.append(String(raw[(index + marker.count)...]))
          index = raw.count
        } else if let block = blockComment, starts(block.open, at: index) {
          blank(index..<(index + block.open.count))
          index += block.open.count
          state = .block(depth: 1)
        } else if let delimiter = strings.first(where: { starts($0.open, at: index) }) {
          index += delimiter.open.count
          state = .string(delimiter)
        } else if characterLiterals, raw[index] == "'", let end = characterEnd(raw, from: index) {
          blank((index + 1)..<end)
          index = end + 1
        } else {
          index += 1
        }
      case .block(let depth):
        guard let block = blockComment else {
          state = .code
          continue
        }
        if starts(block.close, at: index) {
          blank(index..<(index + block.close.count))
          index += block.close.count
          if depth == 1 {
            comments.append(String(comment))
            comment = []
            state = .code
          } else {
            state = .block(depth: depth - 1)
          }
        } else if nestedBlocks, starts(block.open, at: index) {
          blank(index..<(index + block.open.count))
          index += block.open.count
          state = .block(depth: depth + 1)
        } else {
          comment.append(raw[index])
          blank(index..<(index + 1))
          index += 1
        }
      case .string(let delimiter):
        if delimiter.escapes, raw[index] == "\\" {
          blank(index..<min(index + 2, raw.count))
          index += 2
        } else if starts(delimiter.close, at: index) {
          index += delimiter.close.count
          state = .code
        } else {
          blank(index..<(index + 1))
          index += 1
        }
      }
    }
    if case .block = state {
      comments.append(String(comment))
    }
    if case .string(let delimiter) = state, !delimiter.multiline {
      state = .code
    }
    return LexedLine(number: line.number, raw: raw, code: code, comments: comments)
  }

  /// The index of the `'` closing a character literal opened at `start`, if one closes there.
  private func characterEnd(_ raw: [Character], from start: Int) -> Int? {
    if start + 1 < raw.count, raw[start + 1] == "\\" {
      let limit = min(raw.count, start + 12)
      return ((start + 2)..<limit).first { raw[$0] == "'" }
    }
    if start + 2 < raw.count, raw[start + 2] == "'" { return start + 2 }
    return nil
  }
}

extension Character {
  var isIdentifierCharacter: Bool { isLetter || isNumber || self == "_" }
}

extension StringProtocol {
  var trimmedWhitespace: String {
    String(drop { $0.isWhitespace }.reversed().drop { $0.isWhitespace }.reversed())
  }
}

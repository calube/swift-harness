/// Per-language calls and keywords that make a test assert something.
enum AssertionTable {
  static func tokens(for language: AreaLanguage) -> [CodeToken] {
    switch language {
    case .swift:
      [
        CodeToken("XCTAssert", tail: .identifier), CodeToken("XCTFail", tail: .wordEnd),
        CodeToken("XCTUnwrap", tail: .wordEnd), CodeToken("assert", tail: .identifier),
        CodeToken("#expect", wordStart: false, tail: .wordEnd),
        CodeToken("#require", wordStart: false, tail: .wordEnd),
        CodeToken("expectNoDifference", tail: .wordEnd),
      ]
    case .kotlin, .java:
      [
        CodeToken("assert", tail: .identifier), CodeToken("fail", tail: .wordEnd, then: "("),
        CodeToken("verify", tail: .wordEnd, then: "("), CodeToken("should", tail: .identifier),
        CodeToken("expectThat", tail: .wordEnd),
      ]
    case .javascript, .typescript:
      [
        CodeToken("expect", tail: .identifier), CodeToken("assert", tail: .identifier),
        CodeToken(".should", wordStart: false, tail: .identifier),
      ]
    case .python:
      [
        CodeToken("assert", tail: .identifier),
        CodeToken(".assert", wordStart: false, tail: .identifier),
        CodeToken("pytest.raises", tail: .wordEnd), CodeToken("pytest.warns", tail: .wordEnd),
        CodeToken(".fail", wordStart: false, tail: .wordEnd, then: "("),
      ]
    case .go:
      [
        CodeToken("assert.", wordStart: true), CodeToken("require.", wordStart: true),
        CodeToken("t.Error", tail: .identifier), CodeToken("t.Fatal", tail: .identifier),
        CodeToken("t.Fail", tail: .identifier),
      ]
    case .rust:
      [CodeToken("assert", tail: .identifier), CodeToken("debug_assert", tail: .identifier)]
    case .ruby:
      [
        CodeToken("assert", tail: .identifier), CodeToken("refute", tail: .identifier),
        CodeToken("expect", tail: .wordEnd), CodeToken("must_", tail: .identifier),
        CodeToken("wont_", tail: .identifier), CodeToken("flunk", tail: .wordEnd),
        CodeToken(".should", wordStart: false, tail: .identifier),
      ]
    case .other:
      []
    }
  }

  /// 1 assertion's arguments compare constants or a value with itself.
  static func isTautology(_ line: LexedLine, token: Range<Int>, language: AreaLanguage) -> Bool {
    var arguments = Self.arguments(line, after: token.upperBound)
    if language == .go, arguments.first == "t" { arguments.removeFirst() }
    if arguments.count == 1, let comparison = splitComparison(arguments[0]) {
      arguments = comparison
    }
    switch arguments.count {
    case 0: return false
    case 1: return ["true", "True", "!false", "1"].contains(arguments[0])
    default:
      let (left, right) = (arguments[0], arguments[1])
      return left == right || (isLiteral(left) && isLiteral(right))
    }
  }

  /// The top-level arguments of the call or keyword expression that starts at `position`, from
  /// the raw text, so string literals keep their content.
  private static func arguments(_ line: LexedLine, after position: Int) -> [String] {
    var index = position
    while index < line.code.count, line.code[index] == "!" || line.code[index].isWhitespace {
      index += 1
    }
    let start: Int
    var end: Int
    if index < line.code.count, line.code[index] == "(" {
      start = index + 1
      var depth = 1
      end = start
      while end < line.code.count, depth > 0 {
        if "([{".contains(line.code[end]) { depth += 1 }
        if ")]}".contains(line.code[end]) { depth -= 1 }
        if depth > 0 { end += 1 }
      }
      guard depth == 0 else { return [] }
    } else {
      start = index
      end = line.code.count
      while end > start, line.code[end - 1].isWhitespace { end -= 1 }
    }
    var parts: [String] = []
    var depth = 0
    var partStart = start
    for position in start..<end {
      let character = line.code[position]
      if "([{".contains(character) { depth += 1 }
      if ")]}".contains(character) { depth -= 1 }
      if character == ",", depth == 0 {
        parts.append(String(line.raw[partStart..<position]))
        partStart = position + 1
      }
    }
    parts.append(String(line.raw[partStart..<end]))
    return parts.map(\.trimmedWhitespace).filter { !$0.isEmpty }
  }

  private static func splitComparison(_ expression: String) -> [String]? {
    for operator_ in [" == ", " === "] {
      let sides = expression.components(separatedBy: operator_)
      if sides.count == 2 { return sides.map(\.trimmedWhitespace) }
    }
    return nil
  }

  private static func isLiteral(_ text: String) -> Bool {
    if ["true", "false", "True", "False", "nil", "null", "None", "undefined"].contains(text) {
      return true
    }
    if let first = text.first, let last = text.last, text.count >= 2, first == last,
      "\"'`".contains(first)
    {
      return true
    }
    return !text.isEmpty && text.allSatisfy { $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" }
  }
}

/// A test function or test block, located in lexed lines.
struct TestBlock {
  let name: String
  let declarationLine: Int
  let endLine: Int
  /// Each line of the body with the part of it inside the body.
  let body: [(line: LexedLine, range: Range<Int>)]
}

/// Finds test blocks by each language's declaration shape and its block delimiters: braces,
/// indentation, or `do`/`end`. A block whose end can't be seen is left out.
enum TestBlockFinder {
  static func blocks(
    in lines: [LexedLine], language: AreaLanguage, isTest: Bool, reachesEnd: Bool
  ) -> [TestBlock] {
    switch language {
    case .swift, .kotlin, .java, .go, .rust:
      braceBlocks(lines, language: language, isTest: isTest)
    case .javascript, .typescript:
      isTest ? callBlocks(lines) : []
    case .python:
      isTest ? indentedBlocks(lines, reachesEnd: reachesEnd) : []
    case .ruby:
      isTest ? rubyBlocks(lines) : []
    case .other:
      []
    }
  }

  private static func identifier(after token: CodeToken, in line: LexedLine) -> String? {
    guard let match = token.matches(in: line.code).first else { return nil }
    var index = match.upperBound
    while index < line.code.count, line.code[index].isWhitespace { index += 1 }
    let start = index
    while index < line.code.count, line.code[index].isIdentifierCharacter { index += 1 }
    return index > start ? String(line.raw[start..<index]) : nil
  }

  /// Swift, Kotlin, Java, Go and Rust: an attribute or a naming convention marks the function,
  /// and its body runs from its first `{` to the matching `}`.
  private static func braceBlocks(
    _ lines: [LexedLine], language: AreaLanguage, isTest: Bool
  ) -> [TestBlock] {
    let keyword: CodeToken
    switch language {
    case .swift: keyword = CodeToken("func", tail: .wordEnd)
    case .kotlin: keyword = CodeToken("fun", tail: .wordEnd)
    case .java: keyword = CodeToken("void", tail: .wordEnd)
    case .go: keyword = CodeToken("func", tail: .wordEnd)
    default: keyword = CodeToken("fn", tail: .wordEnd)
    }
    let attribute = CodeToken("@Test", wordStart: false, tail: .wordEnd)
    var blocks: [TestBlock] = []
    var marked = false
    for (offset, line) in lines.enumerated() {
      let code = line.codeString
      switch language {
      case .rust:
        let trimmed = code.trimmedWhitespace
        if trimmed.hasPrefix("#["), trimmed.contains("test]") || trimmed.contains("::test") {
          marked = true
        }
      case .go: break
      default:
        if !attribute.matches(in: line.code).isEmpty { marked = true }
      }
      guard let name = identifier(after: keyword, in: line) else { continue }
      let isDeclaration: Bool
      switch language {
      case .go: isDeclaration = name.hasPrefix("Test") && code.contains("*testing.T")
      case .swift: isDeclaration = marked || (isTest && name.hasPrefix("test"))
      default: isDeclaration = marked
      }
      marked = false
      guard isDeclaration, let block = braceBody(lines, from: offset, name: name) else { continue }
      blocks.append(block)
    }
    return blocks
  }

  private static func braceBody(_ lines: [LexedLine], from offset: Int, name: String) -> TestBlock?
  {
    var depth = 0
    var opened: (line: Int, column: Int)?
    var body: [(line: LexedLine, range: Range<Int>)] = []
    for index in offset..<lines.count {
      let line = lines[index]
      if index > offset, line.number != lines[index - 1].number + 1 { return nil }
      if opened == nil, index - offset > 4 { return nil }
      var bodyStart = opened == nil ? nil : 0
      for column in 0..<line.code.count {
        switch line.code[column] {
        case "{":
          if opened == nil {
            opened = (index, column)
            bodyStart = column + 1
          }
          depth += 1
        case "}" where opened != nil:
          depth -= 1
          if depth == 0 {
            body.append((line, (bodyStart ?? 0)..<column))
            return TestBlock(
              name: name, declarationLine: lines[offset].number, endLine: line.number, body: body)
          }
        default: break
        }
      }
      if let bodyStart { body.append((line, bodyStart..<line.code.count)) }
    }
    return nil
  }

  /// JavaScript and TypeScript: `it(…)`, `test(…)` and their `.only`, `.skip` and `.each`
  /// forms; the block is the call's parentheses, its body what follows the name.
  private static func callBlocks(_ lines: [LexedLine]) -> [TestBlock] {
    let callers = ["it", "test", "xit", "fit", "xtest"].map { CodeToken($0, tail: .wordEnd) }
    var blocks: [TestBlock] = []
    for (offset, line) in lines.enumerated() {
      guard let match = callers.lazy.flatMap({ $0.matches(in: line.code) }).first else {
        continue
      }
      var column = match.upperBound
      while column < line.code.count,
        line.code[column] == "." || line.code[column].isIdentifierCharacter
      {
        column += 1
      }
      guard column < line.code.count, line.code[column] == "(" else { continue }
      if let block = callBody(lines, from: offset, column: column) { blocks.append(block) }
    }
    return blocks
  }

  private static func callBody(_ lines: [LexedLine], from offset: Int, column: Int) -> TestBlock? {
    let first = lines[offset]
    let name =
      first.raw[column...].firstIndex { "'\"`".contains($0) }.map { quote in
        String(first.raw[(quote + 1)...].prefix { $0 != first.raw[quote] })
      } ?? first.codeString.trimmedWhitespace
    var depth = 0
    var body: [(line: LexedLine, range: Range<Int>)] = []
    var bodyFrom: (index: Int, column: Int)?
    for index in offset..<lines.count {
      let line = lines[index]
      if index > offset, line.number != lines[index - 1].number + 1 { return nil }
      func bodyRange(upTo end: Int) -> Range<Int>? {
        guard let bodyFrom else { return nil }
        let start = bodyFrom.index == index ? bodyFrom.column : 0
        return start < end ? start..<end : start..<start
      }
      for position in (index == offset ? column : 0)..<line.code.count {
        let character = line.code[position]
        if "([{".contains(character) {
          depth += 1
        } else if ")]}".contains(character) {
          depth -= 1
          guard depth == 0 else { continue }
          if let range = bodyRange(upTo: position) { body.append((line, range)) }
          return TestBlock(
            name: name, declarationLine: first.number, endLine: line.number, body: body)
        } else if character == ",", depth == 1, bodyFrom == nil {
          bodyFrom = (index, position + 1)
        }
      }
      if let range = bodyRange(upTo: line.code.count) { body.append((line, range)) }
    }
    return nil
  }

  /// Python: `def test…`, with a body of the lines indented deeper than the `def`.
  private static func indentedBlocks(_ lines: [LexedLine], reachesEnd: Bool) -> [TestBlock] {
    let def = CodeToken("def", tail: .wordEnd)
    var blocks: [TestBlock] = []
    for (offset, line) in lines.enumerated() {
      guard let name = identifier(after: def, in: line), name.hasPrefix("test") else { continue }
      let indent = line.code.prefix { $0.isWhitespace }.count
      var body: [(line: LexedLine, range: Range<Int>)] = []
      var end: Int?
      var last = line.number
      var index = offset + 1
      while index < lines.count {
        let next = lines[index]
        if next.number != last + 1 { break }
        last = next.number
        if next.codeString.trimmedWhitespace.isEmpty {
          index += 1
          continue
        }
        if next.code.prefix(while: { $0.isWhitespace }).count <= indent {
          end = body.last?.line.number ?? line.number
          break
        }
        body.append((next, 0..<next.code.count))
        index += 1
      }
      if end == nil, index == lines.count, reachesEnd {
        end = body.last?.line.number ?? line.number
      }
      guard let end else { continue }
      blocks.append(TestBlock(name: name, declarationLine: line.number, endLine: end, body: body))
    }
    return blocks
  }

  /// Ruby: `def test_…`, or `it`, `test`, `specify` and `scenario` with a `do` block, closed by the
  /// matching `end`.
  private static func rubyBlocks(_ lines: [LexedLine]) -> [TestBlock] {
    let def = CodeToken("def", tail: .wordEnd, lineStart: true)
    let blockStarters = ["it", "test", "specify", "scenario"].map {
      CodeToken($0, tail: .wordEnd, lineStart: true)
    }
    let doToken = CodeToken("do", tail: .wordEnd)
    let endToken = CodeToken("end", tail: .wordEnd)
    let openers = ["if", "unless", "while", "until", "case", "begin", "def", "class", "module"]
      .map { CodeToken($0, tail: .wordEnd, lineStart: true) }
    var blocks: [TestBlock] = []
    for (offset, line) in lines.enumerated() {
      let name: String
      if let defName = identifier(after: def, in: line), defName.hasPrefix("test_") {
        name = defName
      } else if blockStarters.contains(where: { !$0.matches(in: line.code).isEmpty }),
        !doToken.matches(in: line.code).isEmpty
      {
        name =
          line.raw.firstIndex { "'\"".contains($0) }.map { quote in
            String(line.raw[(quote + 1)...].prefix { $0 != line.raw[quote] })
          } ?? line.codeString.trimmedWhitespace
      } else {
        continue
      }
      var depth = 0
      var body: [(line: LexedLine, range: Range<Int>)] = []
      for index in offset..<lines.count {
        let current = lines[index]
        if index > offset, current.number != lines[index - 1].number + 1 { break }
        depth += doToken.matches(in: current.code).count
        depth += openers.reduce(0) { $0 + $1.matches(in: current.code).count }
        depth -= endToken.matches(in: current.code).count
        if index > offset, depth <= 0 {
          blocks.append(
            TestBlock(
              name: name, declarationLine: line.number, endLine: current.number, body: body))
          break
        }
        if index > offset { body.append((current, 0..<current.code.count)) }
      }
    }
    return blocks
  }
}

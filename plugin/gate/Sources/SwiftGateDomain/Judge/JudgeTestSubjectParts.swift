/// The parts of a test's name that a Jev question reads by path (design §13.2): the whole name, the
/// behaviour it claims, and the regression it says it catches.
public struct JudgeTestName: Sendable, Equatable, Codable {
  /// The first `@Test("…")` display string, unescaped, else the test function's name.
  public let full: String
  /// The text before ` — catches ` (em dash, en dash or hyphen), else `full`.
  public let behavior: String
  /// `catches ` and the text after it; `nil` when the name has no catches part.
  public let catches: String?

  public init(full: String, behavior: String, catches: String?) {
    self.full = full
    self.behavior = behavior
    self.catches = catches
  }

  private enum CodingKeys: String, CodingKey {
    case full, behavior, catches
  }

  /// Writes `catches` as `null` when absent: the Jev questions read a missing catches part as a
  /// signal, so the key must be there either way.
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(full, forKey: .full)
    try container.encode(behavior, forKey: .behavior)
    try container.encode(catches, forKey: .catches)
  }

  static let catchesSeparators = [" — catches ", " – catches ", " - catches "]

  /// Reads the name from the first `@Test` attribute in code: its display string, else the func it
  /// marks. With no `@Test`, as in XCTest, the first func names the test. A backticked name loses its
  /// backticks. Comments and string contents never count as code.
  public static func parse(source: String) -> JudgeTestName {
    let scan = SwiftSourceScan(source)
    let full = scan.testDisplayName() ?? scan.testFunctionName() ?? ""
    let split = catchesSeparators.compactMap { full.firstRange(of: $0) }
      .min { $0.lowerBound < $1.lowerBound }
    guard let split else { return JudgeTestName(full: full, behavior: full, catches: nil) }
    return JudgeTestName(
      full: full,
      behavior: String(full[..<split.lowerBound]),
      catches: "catches " + full[split.upperBound...])
  }
}

/// The assertion statements of a test's source, for the `assertions` state field (design §13.2).
///
/// Recognised: `#expect`, `#require`, `XCTAssert*` and `XCTUnwrap` calls, and `store.send` or
/// `store.receive` calls that follow `await`. Each entry runs from any `try`, `try?`, `try!` or
/// `await` before the call to the parenthesis that closes it, plus trailing closures up to the brace
/// that balances them. A statement over several lines becomes 1 line: each line trimmed, joined by a
/// space, comments dropped. An assertion inside another's extent is part of it, not a new entry.
///
/// Not recognised, on purpose: `XCTFail`, `Issue.record`, `confirmation`, snapshot helpers such as
/// `assertSnapshot`, a store under another name, and custom assertion helpers. Regex literals aren't
/// lexed, so a quote or brace inside one can misplace an extent.
public enum JudgeAssertions {
  public static func extract(source: String) -> [String] {
    SwiftSourceScan(source).assertionStatements()
  }
}

/// A lexed view of Swift source: each character is code, comment or string-literal content, so
/// the parsers above look for keywords and balance brackets in code only.
struct SwiftSourceScan {
  enum Kind { case code, comment, string }

  let chars: [Character]
  let kinds: [Kind]

  init(_ source: String) {
    chars = Array(source)
    var lexer = Lexer(chars: chars)
    lexer.run()
    kinds = lexer.kinds
  }

  // MARK: Names

  func testDisplayName() -> String? {
    guard let attribute = find("@Test", from: 0) else { return nil }
    var index = skipWhitespace(from: attribute + 5, newlines: true)
    guard isCode(index, "(") else { return nil }
    index = skipWhitespace(from: index + 1, newlines: true)
    return StringLiteral.read(chars, at: index)?.value
  }

  func testFunctionName() -> String? {
    let start = find("@Test", from: 0) ?? 0
    guard let keyword = find("func", from: start) else { return nil }
    var index = skipWhitespace(from: keyword + 4, newlines: true)
    if isCode(index, "`") {
      index += 1
      let nameStart = index
      while index < chars.count, chars[index] != "`", chars[index] != "\n" { index += 1 }
      guard index < chars.count, chars[index] == "`" else { return nil }
      return String(chars[nameStart..<index])
    }
    let nameStart = index
    while index < chars.count, Self.isIdentifier(chars[index]) { index += 1 }
    return index > nameStart ? String(chars[nameStart..<index]) : nil
  }

  // MARK: Assertions

  func assertionStatements() -> [String] {
    var statements: [String] = []
    var index = 0
    while index < chars.count {
      guard kinds[index] == .code, startsWord(at: index), let callOpen = assertionCall(at: index)
      else {
        index += 1
        continue
      }
      guard let end = statementEnd(callOpen: callOpen) else { break }
      statements.append(text(from: effectStart(before: index), through: end))
      index = end + 1
    }
    return statements
  }

  /// When an assertion's name starts at `index`, the index of its opening parenthesis.
  private func assertionCall(at index: Int) -> Int? {
    let nameEnd: Int
    if let end = macro(at: index, "#expect") ?? macro(at: index, "#require") {
      nameEnd = end
    } else if matches("XCTAssert", at: index) {
      nameEnd = identifierEnd(from: index)
    } else if matches("XCTUnwrap", at: index), identifierEnd(from: index) == index + 9 {
      nameEnd = index + 9
    } else if let end = storeCall(at: index) {
      nameEnd = end
    } else {
      return nil
    }
    let open = skipWhitespace(from: nameEnd, newlines: false)
    return isCode(open, "(") ? open : nil
  }

  private func macro(at index: Int, _ name: String) -> Int? {
    guard matches(name, at: index) else { return nil }
    let end = index + name.count
    return end < chars.count && Self.isIdentifier(chars[end]) ? nil : end
  }

  private func storeCall(at index: Int) -> Int? {
    guard matches("store", at: index), identifierEnd(from: index) == index + 5 else { return nil }
    let dot = skipWhitespace(from: index + 5, newlines: false)
    guard isCode(dot, ".") else { return nil }
    let method = dot + 1
    let methodEnd = identifierEnd(from: method)
    let name = String(chars[method..<methodEnd])
    guard name == "send" || name == "receive" else { return nil }
    guard let previous = wordBefore(index), previous.word == "await" else { return nil }
    return methodEnd
  }

  /// The last character of a call opened at `callOpen`, with its trailing closures.
  private func statementEnd(callOpen: Int) -> Int? {
    guard var end = closingIndex(of: callOpen) else { return nil }
    while true {
      var next = skipWhitespace(from: end + 1, newlines: false)
      if isCode(next, "{"), let close = closingIndex(of: next) {
        end = close
        continue
      }
      guard end < chars.count, chars[end] == "}" else { return end }
      let label = identifierEnd(from: next)
      guard label > next else { return end }
      next = skipWhitespace(from: label, newlines: false)
      guard isCode(next, ":") else { return end }
      next = skipWhitespace(from: next + 1, newlines: false)
      guard isCode(next, "{"), let close = closingIndex(of: next) else { return end }
      end = close
    }
  }

  /// Walks back over `try`, `try?`, `try!` and `await` on the same line.
  private func effectStart(before index: Int) -> Int {
    var start = index
    while let previous = wordBefore(start) {
      guard ["try", "try?", "try!", "await"].contains(previous.word) else { break }
      start = previous.start
    }
    return start
  }

  private func wordBefore(_ index: Int) -> (word: String, start: Int)? {
    var end = index
    while end > 0, chars[end - 1] == " " || chars[end - 1] == "\t" { end -= 1 }
    guard end < index, end > 0, kinds[end - 1] == .code else { return nil }
    var start = end
    if chars[start - 1] == "?" || chars[start - 1] == "!" { start -= 1 }
    while start > 0, Self.isIdentifier(chars[start - 1]) { start -= 1 }
    guard start < end, startsWord(at: start) else { return nil }
    return (String(chars[start..<end]), start)
  }

  private func closingIndex(of open: Int) -> Int? {
    var stack: [Character] = []
    var index = open
    while index < chars.count {
      if kinds[index] == .code {
        switch chars[index] {
        case "(": stack.append(")")
        case "[": stack.append("]")
        case "{": stack.append("}")
        case ")", "]", "}":
          guard stack.last == chars[index] else { return nil }
          stack.removeLast()
          if stack.isEmpty { return index }
        default: break
        }
      }
      index += 1
    }
    return nil
  }

  private func text(from start: Int, through end: Int) -> String {
    var lines: [String] = []
    var line = ""
    for index in start...end {
      if chars[index] == "\n" {
        lines.append(line)
        line = ""
      } else if kinds[index] != .comment {
        line.append(chars[index])
      }
    }
    lines.append(line)
    return lines.map { $0.trimmingWhitespace() }.filter { !$0.isEmpty }.joined(separator: " ")
  }

  // MARK: Helpers

  private func find(_ word: String, from start: Int) -> Int? {
    var index = start
    while index < chars.count {
      if kinds[index] == .code, startsWord(at: index), matches(word, at: index) {
        let end = index + word.count
        if end >= chars.count || !Self.isIdentifier(chars[end]) { return index }
      }
      index += 1
    }
    return nil
  }

  private func matches(_ word: String, at index: Int) -> Bool {
    var position = index
    for character in word {
      guard position < chars.count, kinds[position] == .code, chars[position] == character else {
        return false
      }
      position += 1
    }
    return true
  }

  /// No identifier character or member dot directly before `index`.
  private func startsWord(at index: Int) -> Bool {
    guard index > 0 else { return true }
    let previous = chars[index - 1]
    return !Self.isIdentifier(previous) && previous != "." && previous != "#" && previous != "@"
  }

  private func identifierEnd(from index: Int) -> Int {
    var end = index
    while end < chars.count, kinds[end] == .code, Self.isIdentifier(chars[end]) { end += 1 }
    return end
  }

  private func skipWhitespace(from index: Int, newlines: Bool) -> Int {
    var index = index
    while index < chars.count,
      kinds[index] == .comment || chars[index] == " " || chars[index] == "\t"
        || (newlines && chars[index].isNewline)
    {
      index += 1
    }
    return index
  }

  private func isCode(_ index: Int, _ character: Character) -> Bool {
    index < chars.count && kinds[index] == .code && chars[index] == character
  }

  static func isIdentifier(_ character: Character) -> Bool {
    character == "_" || character.isLetter || character.isNumber
  }
}

/// Marks each character of Swift source as code, comment or string content. String delimiters
/// stay code, so a parser can find where a literal starts.
private struct Lexer {
  let chars: [Character]
  var kinds: [SwiftSourceScan.Kind]
  var index = 0

  init(chars: [Character]) {
    self.chars = chars
    kinds = Array(repeating: .code, count: chars.count)
  }

  mutating func run() {
    while index < chars.count { step() }
  }

  /// Consumes 1 comment, 1 string literal or 1 code character.
  private mutating func step() {
    if at("//") {
      while index < chars.count, !chars[index].isNewline { mark(.comment) }
    } else if at("/*") {
      blockComment()
    } else if let hashes = stringStart() {
      string(hashes: hashes)
    } else {
      index += 1
    }
  }

  private mutating func blockComment() {
    var depth = 0
    repeat {
      if at("/*") {
        depth += 1
        mark(.comment)
        mark(.comment)
      } else if at("*/") {
        depth -= 1
        mark(.comment)
        mark(.comment)
      } else {
        mark(.comment)
      }
    } while depth > 0 && index < chars.count
  }

  /// The number of `#` before a quote that opens a string here, or nil.
  private func stringStart() -> Int? {
    var position = index
    while position < chars.count, chars[position] == "#" { position += 1 }
    guard position < chars.count, chars[position] == "\"" else { return nil }
    return position - index
  }

  private mutating func string(hashes: Int) {
    index += hashes
    let multiLine = at("\"\"\"")
    index += multiLine ? 3 : 1
    let closing = delimiter(multiLine: multiLine, hashes: hashes)
    let escape = "\\" + String(repeating: "#", count: hashes)
    while index < chars.count {
      if at(closing) {
        index += closing.count
        return
      }
      if !multiLine, chars[index].isNewline { return }
      if at(escape) {
        for _ in 0..<escape.count { mark(.string) }
        if index < chars.count, chars[index] == "(" {
          interpolation()
        } else if index < chars.count {
          mark(.string)
        }
        continue
      }
      mark(.string)
    }
  }

  /// An interpolation's code, nested strings included, is string content to the outer scan.
  private mutating func interpolation() {
    var depth = 0
    let start = index
    while index < chars.count {
      if chars[index] == "(" {
        depth += 1
        index += 1
      } else if chars[index] == ")" {
        depth -= 1
        index += 1
        if depth == 0 { break }
      } else {
        step()
      }
    }
    for position in start..<index { kinds[position] = .string }
  }

  private func at(_ text: String) -> Bool {
    var position = index
    for character in text {
      guard position < chars.count, chars[position] == character else { return false }
      position += 1
    }
    return true
  }

  private mutating func mark(_ kind: SwiftSourceScan.Kind) {
    kinds[index] = kind
    index += 1
  }
}

/// Reads the value of a string literal: escapes resolved, interpolations kept as written.
private enum StringLiteral {
  static func read(_ chars: [Character], at start: Int) -> (value: String, end: Int)? {
    var index = start
    var hashes = 0
    while index < chars.count, chars[index] == "#" {
      hashes += 1
      index += 1
    }
    guard index < chars.count, chars[index] == "\"" else { return nil }
    let multiLine = index + 2 < chars.count && chars[index + 1] == "\"" && chars[index + 2] == "\""
    index += multiLine ? 3 : 1
    let closing = Array(delimiter(multiLine: multiLine, hashes: hashes))
    var raw: [Character] = []
    while index < chars.count {
      if Array(chars[index..<min(index + closing.count, chars.count)]) == closing {
        let body = multiLine ? dedent(raw) : raw
        return (unescape(body, hashes: hashes), index + closing.count)
      }
      if !multiLine, chars[index].isNewline { return nil }
      let escapeEnd = index + hashes + 1
      if chars[index] == "\\", escapeEnd < chars.count,
        chars[(index + 1)..<escapeEnd].allSatisfy({ $0 == "#" })
      {
        raw.append(contentsOf: chars[index...escapeEnd])
        index = escapeEnd + 1
        continue
      }
      raw.append(chars[index])
      index += 1
    }
    return nil
  }

  /// A multi-line literal drops its first and last line breaks and the closing line's indent.
  private static func dedent(_ raw: [Character]) -> [Character] {
    var lines = String(raw).split(separator: "\n", omittingEmptySubsequences: false)
    let indent = lines.last.map(indentWidth) ?? 0
    if lines.count > 1 { lines.removeLast() }
    if lines.first?.allSatisfy(\.isWhitespace) == true { lines.removeFirst() }
    let dedented = lines.map { $0.dropFirst(min(indent, indentWidth($0))) }
    return Array(dedented.joined(separator: "\n"))
  }

  private static func indentWidth(_ line: Substring) -> Int {
    line.prefix { $0 == " " || $0 == "\t" }.count
  }

  private static func unescape(_ raw: [Character], hashes: Int) -> String {
    let escape = Array("\\" + String(repeating: "#", count: hashes))
    var value = ""
    var index = 0
    while index < raw.count {
      guard Array(raw[index..<min(index + escape.count, raw.count)]) == escape,
        index + escape.count < raw.count
      else {
        value.append(raw[index])
        index += 1
        continue
      }
      let code = raw[index + escape.count]
      index += escape.count + 1
      switch code {
      case "n": value.append("\n")
      case "t": value.append("\t")
      case "r": value.append("\r")
      case "0": value.append("\0")
      case "\\", "\"", "'": value.append(code)
      case "u":
        guard index < raw.count, raw[index] == "{", let close = raw[index...].firstIndex(of: "}"),
          let code = UInt32(String(raw[(index + 1)..<close]), radix: 16),
          let scalar = Unicode.Scalar(code)
        else {
          value.append(contentsOf: escape + ["u"])
          continue
        }
        value.unicodeScalars.append(scalar)
        index = close + 1
      default:
        value.append(contentsOf: escape + [code])
      }
    }
    return value
  }
}

/// A string literal's closing delimiter.
private func delimiter(multiLine: Bool, hashes: Int) -> String {
  String(repeating: "\"", count: multiLine ? 3 : 1) + String(repeating: "#", count: hashes)
}

extension String {
  fileprivate func trimmingWhitespace() -> String {
    let characters = Array(self)
    guard let first = characters.firstIndex(where: { !$0.isWhitespace }),
      let last = characters.lastIndex(where: { !$0.isWhitespace })
    else { return "" }
    return String(characters[first...last])
  }
}

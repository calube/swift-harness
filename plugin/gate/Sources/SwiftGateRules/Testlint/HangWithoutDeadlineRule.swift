import SwiftGateDomain
import SwiftSyntax

/// A script or source a test writes out that waits forever leaks a process on every prove and
/// mutate run that reverts the fix it guards; it must end by itself (testing playbook P12).
struct HangWithoutDeadlineRule: FileRule {
  static let id = "test.hang-without-deadline"

  let descriptor = RuleDescriptor(
    id: Self.id, severity: .major,
    summary: "a script or source a test writes out waits forever with no deadline")
  let scope = RuleScope.testFiles

  func check(_ unit: SourceUnit, context: RuleContext) -> [RuleViolation] {
    unit.tree.descendants(of: StringLiteralExprSyntax.self).compactMap { literal in
      let text = Self.content(of: literal)
      guard let shape = HangScan.foreverShape(in: text), !HangScan.setsDeadline(text) else {
        return nil
      }
      return unit.violation(
        at: literal,
        message:
          "this literal writes out code that waits forever (`\(shape)`) and sets no deadline; "
          + "give it its own (a `Date` or `DispatchTime` deadline, `timeout <n>`, `alarm(`) or "
          + "an exit, so a copy a killed or reverted run leaves behind ends by itself",
        failureScenario:
          "prove and mutate revert the fix and leave a spinning process behind on every run")
    }
  }

  /// The literal's text as the written-out file sees it: escapes decoded, each interpolation
  /// replaced by a number so a `timeout \(n)` still reads as a bound.
  static func content(of literal: StringLiteralExprSyntax) -> String {
    let raw = literal.openingPounds != nil
    return literal.segments.map { segment in
      guard let text = segment.as(StringSegmentSyntax.self)?.content.text else { return "1" }
      return raw ? text : unescape(text)
    }.joined()
  }

  private static func unescape(_ text: String) -> String {
    var result = ""
    var escaping = false
    for character in text {
      if escaping {
        switch character {
        case "n": result.append("\n")
        case "t": result.append("\t")
        case "r": result.append("\r")
        case "0": break
        default: result.append(character)
        }
        escaping = false
      } else if character == "\\" {
        escaping = true
      } else {
        result.append(character)
      }
    }
    return result
  }
}

/// Text-level shapes of code that never ends, in the languages tests write out (Swift, C, shell,
/// Python). Heuristic by design: a literal is not parsed as any one language.
enum HangScan {
  /// The first forever-waiting construct in `text`, as a short label, or nil.
  static func foreverShape(in text: String) -> String? {
    let waits: [(Regex<Substring>, String)] = [
      (/\bsleep\s+infinity\b/.wordBoundaryKind(.simple), "sleep infinity"),
      (/\bRunLoop\b[\w.]*\.run\(\s*\)/.wordBoundaryKind(.simple), "RunLoop.run()"),
      (/\bdispatchMain\(\s*\)/.wordBoundaryKind(.simple), "dispatchMain()"),
      (/\bpause\(\s*\)/.wordBoundaryKind(.simple), "pause()"),
    ]
    for (pattern, label) in waits where text.contains(pattern) { return label }
    return braceLoop(in: text) ?? repeatLoop(in: text) ?? shellLoop(in: text)
      ?? pythonLoop(in: text)
  }

  static func setsDeadline(_ text: String) -> Bool {
    let bounds: [Regex<Substring>] = [
      /\bDate\b/, /deadline/.ignoresCase(), /\bDispatchTime\b/, /\btime\.time\(\)/,
      /\btimeout\s+\d/, /\balarm\(/, /\bwithTimeout\b/,
    ]
    return bounds.contains { text.contains($0.wordBoundaryKind(.simple)) }
  }

  private static var exits: Regex<Substring> { /\b(?:return|_?exit)\b/.wordBoundaryKind(.simple) }
  private static var breaks: Regex<Substring> { /\bbreak\b/.wordBoundaryKind(.simple) }

  /// `while true {`, `while (1) {`, `for (;;) {` whose body never leaves the loop.
  private static func braceLoop(in text: String) -> String? {
    let heads: [(Regex<Substring>, String)] = [
      (/\bwhile\s*(?:\(\s*)?(?:true|1)(?:\s*\))?\s*\{/, "while true"),
      (/\bfor\s*\(\s*;\s*;\s*\)\s*\{/, "for (;;)"),
    ]
    for (head, label) in heads {
      for match in text.matches(of: head.wordBoundaryKind(.simple)) {
        let open = text.index(before: match.range.upperBound)
        let body = text[bracedBody(in: text, openingAt: open)]
        if !leavesBraceLoop(body) { return label }
      }
    }
    return nil
  }

  /// `repeat { … } while true` and `do { … } while (1)`.
  private static func repeatLoop(in text: String) -> String? {
    for match in text.matches(of: /\}\s*while\s*(?:\(\s*)?(?:true|1)(?:\s*\))?(?!\s*\{)/) {
      let close = match.range.lowerBound
      guard let open = matchingOpenBrace(in: text, closingAt: close) else { continue }
      if !leavesBraceLoop(text[text.index(after: open)..<close]) {
        return "repeat … while true"
      }
    }
    return nil
  }

  /// `while :; do … done` and `while true` / `do` on separate lines.
  private static func shellLoop(in text: String) -> String? {
    for match in text.matches(of: /\bwhile\s+(true|:)\s*[;\n]\s*do\b/.wordBoundaryKind(.simple)) {
      let body = shellBody(in: text, from: match.range.upperBound)
      if !body.contains(exits), !body.contains(breaks) { return "while \(match.output.1)" }
    }
    return nil
  }

  /// `while True:` (or `while 1:`) with the indented lines under it as its body.
  private static func pythonLoop(in text: String) -> String? {
    for match in text.matches(of: /\bwhile\s+(?:True|1)\s*:/.wordBoundaryKind(.simple)) {
      let lineStart =
        text[..<match.range.lowerBound].lastIndex(of: "\n").map(text.index(after:))
        ?? text.startIndex
      let indent = text[lineStart...].prefix { $0 == " " || $0 == "\t" }.count
      let rest = text[match.range.upperBound...]
      let firstLineEnd = rest.firstIndex(of: "\n") ?? rest.endIndex
      var body = String(rest[..<firstLineEnd])
      if body.allSatisfy(\.isWhitespace), firstLineEnd < rest.endIndex {
        for line in rest[rest.index(after: firstLineEnd)...].split(
          separator: "\n", omittingEmptySubsequences: false)
        {
          guard !line.allSatisfy(\.isWhitespace) else { continue }
          guard line.prefix(while: { $0 == " " || $0 == "\t" }).count > indent else { break }
          body += "\n" + line
        }
      }
      if !body.contains(exits), !body.contains(breaks) { return "while True:" }
    }
    return nil
  }

  /// A `return` or `exit` anywhere leaves the loop; a `break` does only outside nested loops.
  private static func leavesBraceLoop(_ body: Substring) -> Bool {
    if body.contains(exits) { return true }
    var outer = String(body)
    while let nested = outer.firstMatch(
      of: /\b(?:for|while|repeat)\b[^{};]*\{/.wordBoundaryKind(.simple))
    {
      let open = outer.index(before: nested.range.upperBound)
      let inner = bracedBody(in: outer, openingAt: open)
      let end =
        inner.upperBound < outer.endIndex ? outer.index(after: inner.upperBound) : inner.upperBound
      outer.replaceSubrange(nested.range.lowerBound..<end, with: " ")
    }
    return outer.contains(breaks)
  }

  /// The text between the brace at `open` and its match, or to the end when it never closes.
  private static func bracedBody(in text: String, openingAt open: String.Index) -> Range<
    String.Index
  > {
    var depth = 0
    var index = text.index(after: open)
    while index < text.endIndex {
      switch text[index] {
      case "{": depth += 1
      case "}":
        if depth == 0 { return text.index(after: open)..<index }
        depth -= 1
      default: break
      }
      index = text.index(after: index)
    }
    return text.index(after: open)..<text.endIndex
  }

  private static func matchingOpenBrace(in text: String, closingAt close: String.Index)
    -> String.Index?
  {
    var depth = 0
    var index = close
    while index > text.startIndex {
      index = text.index(before: index)
      switch text[index] {
      case "}": depth += 1
      case "{":
        if depth == 0 { return index }
        depth -= 1
      default: break
      }
    }
    return nil
  }

  /// From after a loop's `do` to its `done`, counting `do`/`done` only in command position so a
  /// word like `[ -f done ]` doesn't end the body.
  private static func shellBody(in text: String, from start: String.Index) -> Substring {
    var depth = 0
    for match in text[start...].matches(of: /(?:^|[;\n&|])\s*(do|done)\b/.wordBoundaryKind(.simple))
    {
      if match.output.1 == "do" {
        depth += 1
      } else if depth == 0 {
        return text[start..<match.range.lowerBound]
      } else {
        depth -= 1
      }
    }
    return text[start...]
  }
}

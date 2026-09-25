import SwiftGateDomain
import SwiftSyntax

/// Comment-discipline rules (standards K1–K2). Blocking rules are high precision; warning rules
/// feed the judgment pass and never fail the gate.
public enum CommentRules {
  public static let all: [any Rule] = [
    CommentedOutCodeRule(), DiffNarrationRule(), LineReferenceRule(), TodoWithoutLinkRule(),
    PrivateReferenceRule(), UnjustifiedSuppressionRule(), LongBlockRule(), RestatesCodeRule(),
    TestBodyCommentRule(), TrivialPrivateDocRule(), AIProseRule(),
  ]
}

/// A rule that inspects each non-exempt comment's text for a pattern.
private protocol CommentPatternRule: FileRule {
  var includesDocComments: Bool { get }
  func matches(in comment: SourceComment, context: RuleContext) -> [(line: Int, message: String)]
}

extension CommentPatternRule {
  var scope: RuleScope { .allFiles }
  var includesDocComments: Bool { true }

  func check(_ unit: SourceUnit, context: RuleContext) -> [RuleViolation] {
    unit.comments
      .filter { !$0.isExempt && (includesDocComments || !$0.kind.isDoc) }
      .flatMap { comment in
        matches(in: comment, context: context).map {
          RuleViolation(path: unit.path, lines: $0.line...$0.line, message: $0.message)
        }
      }
  }
}

// MARK: - Blocking

struct CommentedOutCodeRule: FileRule {
  let descriptor = RuleDescriptor(
    id: "comments.commented-out-code", severity: .major,
    summary: "commented-out code (the comment parses as Swift)")
  let scope = RuleScope.allFiles

  private let message = "commented-out code; delete it (history lives in git)"

  func check(_ unit: SourceUnit, context: RuleContext) -> [RuleViolation] {
    var violations: [RuleViolation] = []
    for block in unit.lineCommentBlocks {
      let whole = block.map(\.body).joined(separator: "\n")
      if SwiftCodeHeuristic.isLikelyCode(whole) {
        let lines = block[0].startLine...block[block.count - 1].endLine
        violations.append(RuleViolation(path: unit.path, lines: lines, message: message))
        continue
      }
      guard block.count > 1 else { continue }
      for comment in block where SwiftCodeHeuristic.isLikelyCode(comment.body) {
        violations.append(
          RuleViolation(
            path: unit.path, lines: comment.startLine...comment.endLine, message: message))
      }
    }
    let others = unit.comments.filter {
      !$0.isExempt && ($0.kind == .block || ($0.kind == .line && $0.isTrailing))
    }
    for comment in others where SwiftCodeHeuristic.isLikelyCode(comment.body) {
      violations.append(
        RuleViolation(
          path: unit.path, lines: comment.startLine...comment.endLine, message: message))
    }
    return violations
  }
}

struct DiffNarrationRule: CommentPatternRule {
  let descriptor = RuleDescriptor(
    id: "comments.diff-narration", severity: .major,
    summary: "comment narrates history (previously, now uses, this PR)")

  func matches(in comment: SourceComment, context: RuleContext) -> [(line: Int, message: String)] {
    // The bare adverb is matched only where it opens a sentence or follows a copula, so the
    // adjective use ("the previously cached value") passes.
    let patterns: [Regex<Substring>] = [
      /(?:^|[.;!?]\s+|\/\/\/?\s*|\*\s*)previously\b/.ignoresCase(),
      /\b(?:was|were|is|are|had been)\s+previously\b/.ignoresCase(),
      /\bpreviously,/.ignoresCase(),
      /\bnow uses\b/.ignoresCase(),
      /\bswitched (?:from|to)\b/.ignoresCase(),
      /\bchanged from\b/.ignoresCase(),
      /\bthis (?:PR|pull request|commit)\b/.ignoresCase(),
      /\bin this (?:PR|pull request|commit|change)\b/.ignoresCase(),
      /\bfixed (?:a |the )?bug where\b/.ignoresCase(),
    ]
    let lines = Set(patterns.flatMap(comment.matchLines)).sorted()
    return lines.map {
      ($0, "comment narrates history; put it in the commit message and describe the code as it is")
    }
  }
}

struct LineReferenceRule: CommentPatternRule {
  let descriptor = RuleDescriptor(
    id: "comments.line-reference", severity: .major,
    summary: "comment references line numbers")

  func matches(in comment: SourceComment, context: RuleContext) -> [(line: Int, message: String)] {
    let patterns: [Regex<Substring>] = [
      /\blines?\s+\d+/.ignoresCase(),
      /\b[\w.-]+\.swift:\d+/,
      /#L\d+/,
    ]
    return Set(patterns.flatMap(comment.matchLines)).sorted().map {
      ($0, "line-number reference; they drift on every edit, so name the symbol instead")
    }
  }
}

struct TodoWithoutLinkRule: CommentPatternRule {
  let descriptor = RuleDescriptor(
    id: "comments.todo-without-link", severity: .major,
    summary: "TODO/FIXME without an issue link")

  func matches(in comment: SourceComment, context: RuleContext) -> [(line: Int, message: String)] {
    let links: [Regex<Substring>] = [
      /https?:\/\/\S+/, /(?:^|[\s(])#\d+\b/, /\b[A-Z][A-Z0-9]+-\d+\b/,
    ]
    let commentLines = comment.text.split(separator: "\n", omittingEmptySubsequences: false)
    var result: [(line: Int, message: String)] = []
    for (index, line) in commentLines.enumerated() where line.contains(/\b(?:TODO|FIXME)\b/) {
      guard !links.contains(where: { line.contains($0) }) else { continue }
      result.append(
        (
          comment.startLine + index,
          "TODO/FIXME without an issue link; add the issue URL, #number or tracker key"
        ))
    }
    return result
  }
}

struct PrivateReferenceRule: CommentPatternRule {
  let descriptor = RuleDescriptor(
    id: "comments.private-reference", severity: .major,
    summary: "local machine path or private codename in a comment")

  func matches(in comment: SourceComment, context: RuleContext) -> [(line: Int, message: String)] {
    let paths: [Regex<Substring>] = [
      /\/Users\/[^\/\s]+/, /\/home\/[^\/\s]+/, /\/private\/var\//,
      /\/var\/folders\//, /[A-Za-z]:\\Users\\/,
    ]
    var result = Set(paths.flatMap(comment.matchLines)).sorted().map {
      ($0, "local machine path; use a repository-relative path")
    }
    for codename in context.privateCodenames where !codename.isEmpty {
      for match in comment.text.ranges(of: codename)
      where isWholeWord(match, in: comment.text) {
        result.append(
          (
            comment.line(atTextOffset: match.lowerBound),
            "private codename \"\(codename)\"; describe the work in terms a new reader knows"
          ))
      }
    }
    return result
  }

  private func isWholeWord(_ range: Range<String.Index>, in text: String) -> Bool {
    let before =
      range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
    let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
    return !(before?.isLetter ?? false) && !(before?.isNumber ?? false)
      && !(after?.isLetter ?? false) && !(after?.isNumber ?? false)
  }
}

/// Suppressions and unsafe escape hatches on added lines need a same-line reason.
struct UnjustifiedSuppressionRule: FileRule {
  let descriptor = RuleDescriptor(
    id: "comments.unjustified-suppression", severity: .major,
    summary: "suppression or unsafe construct without a same-line reason")
  let scope = RuleScope.allFiles

  private static let thirdPartyDirectives = [
    "swiftlint:disable", "swiftformat:disable", "periphery:ignore",
  ]

  func check(_ unit: SourceUnit, context: RuleContext) -> [RuleViolation] {
    var violations: [RuleViolation] = []
    for comment in unit.comments where comment.kind == .line || comment.kind == .block {
      if let directive = Self.thirdPartyDirectives.first(where: comment.body.hasPrefix),
        !Self.hasReason(comment.body)
      {
        violations.append(
          RuleViolation(
            path: unit.path, lines: comment.startLine...comment.startLine,
            message: "`\(directive)` without a reason; append ` — <why>` on the same line"))
      }
    }
    for directive in unit.allowDirectives where directive.reason == nil {
      violations.append(
        RuleViolation(
          path: unit.path, lines: directive.line...directive.line,
          message:
            "swiftgate:allow \(directive.ruleID) without a reason; write "
            + "`// swiftgate:allow \(directive.ruleID) — <why this is safe>`"))
    }
    for (token, ruleID, construct) in unsafeConstructs(in: unit) {
      let line = unit.line(of: token.positionAfterSkippingLeadingTrivia)
      guard !unit.hasJustifiedAllow(for: ruleID, onLine: line) else { continue }
      violations.append(
        RuleViolation(
          path: unit.path, lines: line...line,
          message:
            "\(construct) needs a same-line `// swiftgate:allow \(ruleID) — <reason>` naming the "
            + "invariant that makes it safe"))
    }
    return violations
  }

  static func hasReason(_ body: String) -> Bool {
    for separator in ["—", "--"] {
      if let range = body.range(of: separator), !body[range.upperBound...].trimmed.isEmpty {
        return true
      }
    }
    return false
  }

  private func unsafeConstructs(in unit: SourceUnit) -> [(TokenSyntax, String, String)] {
    var found: [(TokenSyntax, String, String)] = []
    for expr in unit.tree.descendants(of: TryExprSyntax.self)
    where expr.questionOrExclamationMark?.tokenKind == .exclamationMark {
      found.append((expr.tryKeyword, "safety.try-bang", "`try!`"))
    }
    for expr in unit.tree.descendants(of: AsExprSyntax.self)
    where expr.questionOrExclamationMark?.tokenKind == .exclamationMark {
      found.append((expr.asKeyword, "safety.as-bang", "`as!`"))
    }
    for expr in unit.tree.descendants(of: UnresolvedAsExprSyntax.self)
    where expr.questionOrExclamationMark?.tokenKind == .exclamationMark {
      found.append((expr.asKeyword, "safety.as-bang", "`as!`"))
    }
    for attribute in unit.tree.descendants(of: AttributeSyntax.self) {
      switch attribute.attributeName.trimmedDescription {
      case "unchecked":
        found.append(
          (attribute.atSign, "safety.unchecked-sendable", "`@unchecked Sendable`"))
      case "preconcurrency":
        found.append((attribute.atSign, "safety.preconcurrency", "`@preconcurrency`"))
      default: break
      }
    }
    for modifier in unit.tree.descendants(of: DeclModifierSyntax.self)
    where modifier.name.tokenKind == .keyword(.nonisolated)
      && modifier.detail?.detail.text == "unsafe"
    {
      found.append((modifier.name, "safety.nonisolated-unsafe", "`nonisolated(unsafe)`"))
    }
    return found
  }
}

// MARK: - Warnings

struct LongBlockRule: FileRule {
  let descriptor = RuleDescriptor(
    id: "comments.long-block", severity: .minor, summary: "comment block over 3 lines")
  let scope = RuleScope.allFiles

  static let maxLines = 3

  func check(_ unit: SourceUnit, context: RuleContext) -> [RuleViolation] {
    let firstToken = unit.tree.firstToken(viewMode: .sourceAccurate)
    var spans: [ClosedRange<Int>] = []
    for block in unit.lineCommentBlocks {
      let isFileHeader = block[0].startLine == 1 && block[0].anchor.id == firstToken?.id
      if !isFileHeader, block.count > Self.maxLines {
        spans.append(block[0].startLine...block[block.count - 1].endLine)
      }
    }
    for comment in unit.comments
    where comment.kind == .block && !comment.isExempt
      && comment.endLine - comment.startLine + 1 > Self.maxLines
    {
      spans.append(comment.startLine...comment.endLine)
    }
    return spans.map {
      RuleViolation(
        path: unit.path, lines: $0,
        message:
          "comment block of \($0.count) lines; keep the one fact the code can't say, move the rest "
          + "to the commit message or docs")
    }
  }
}

/// A comment directly above `if`/`guard`/`return`/`catch` whose words are mostly the statement's
/// own identifiers.
struct RestatesCodeRule: FileRule {
  let descriptor = RuleDescriptor(
    id: "comments.restates-code", severity: .minor,
    summary: "comment restates the if/guard/return/catch below it")
  let scope = RuleScope.allFiles

  static let stopWords: Set<String> = [
    "a", "an", "the", "if", "is", "are", "we", "to", "of", "and", "or", "then", "check", "checks",
    "whether", "when", "return", "returns", "guard", "catch", "this", "that", "it", "not", "no",
    "else", "early", "for", "in", "on", "be", "has", "have", "there", "out", "bail", "otherwise",
    "handle", "get", "set", "value", "make", "sure",
  ]

  func check(_ unit: SourceUnit, context: RuleContext) -> [RuleViolation] {
    var violations: [RuleViolation] = []
    for block in unit.lineCommentBlocks {
      guard let last = block.last, !last.isFollowedByBlankLine,
        let statementWords = Self.statementWords(after: last.anchor)
      else { continue }
      let commentWords = block.flatMap { Self.words(in: $0.body) }
        .filter { !Self.stopWords.contains($0) }
      guard !commentWords.isEmpty, commentWords.count <= 6 else { continue }
      let overlap = commentWords.filter { statementWords.contains($0) }.count
      if overlap * 2 >= commentWords.count {
        violations.append(
          RuleViolation(
            path: unit.path, lines: block[0].startLine...last.endLine,
            message: "comment restates the code below it; delete it or say why instead"))
      }
    }
    return violations
  }

  private static func statementWords(after token: TokenSyntax) -> Set<String>? {
    let node: Syntax?
    switch token.tokenKind {
    case .keyword(.if):
      node = token.parent?.as(IfExprSyntax.self).map { Syntax($0.conditions) }
    case .keyword(.guard):
      node = token.parent?.as(GuardStmtSyntax.self).map { Syntax($0.conditions) }
    case .keyword(.return):
      node = token.parent?.as(ReturnStmtSyntax.self)?.expression.map { Syntax($0) }
    case .keyword(.catch):
      node = token.parent?.as(CatchClauseSyntax.self).map { Syntax($0.catchItems) }
    default:
      return nil
    }
    guard let node else { return [] }
    return Set(
      node.tokens(viewMode: .sourceAccurate).flatMap { token -> [String] in
        guard case .identifier(let text) = token.tokenKind else { return [] }
        return words(in: text)
      })
  }

  /// Lowercased words, splitting camelCase and dropping a plural `s`, so `isLoggedIn` matches
  /// "logged in" and `items` matches "item".
  static func words(in text: String) -> [String] {
    var words: [String] = []
    var current = ""
    var previousWasLower = false
    for character in text {
      if character.isLetter {
        if character.isUppercase, previousWasLower, !current.isEmpty {
          words.append(current)
          current = ""
        }
        current.append(character)
        previousWasLower = character.isLowercase
      } else {
        if !current.isEmpty { words.append(current) }
        current = ""
        previousWasLower = false
      }
    }
    if !current.isEmpty { words.append(current) }
    return words.map { word in
      let lower = word.lowercased()
      return lower.count > 3 && lower.hasSuffix("s") && !lower.hasSuffix("ss")
        ? String(lower.dropLast()) : lower
    }
  }
}

struct TestBodyCommentRule: FileRule {
  let descriptor = RuleDescriptor(
    id: "comments.test-body", severity: .minor,
    summary: "comment inside a test body (the test name should carry the meaning)")
  let scope = RuleScope.testFiles

  func check(_ unit: SourceUnit, context: RuleContext) -> [RuleViolation] {
    let bodies = TestFunction.all(in: unit).compactMap(\.body)
    return unit.comments.filter { comment in
      !comment.isExempt && !comment.isTrailing
        && bodies.contains { body in
          comment.anchor.isDescendant(of: body) && comment.anchor.id != body.leftBrace.id
            || comment.anchor.id == body.rightBrace.id
        }
    }.map {
      RuleViolation(
        path: unit.path, lines: $0.startLine...$0.endLine,
        message: "comment inside a test body; put the meaning in the @Test name or a helper's name")
    }
  }
}

struct TrivialPrivateDocRule: FileRule {
  let descriptor = RuleDescriptor(
    id: "comments.trivial-private-doc", severity: .minor,
    summary: "/// doc comment on a trivial private declaration")
  let scope = RuleScope.allFiles

  func check(_ unit: SourceUnit, context: RuleContext) -> [RuleViolation] {
    unit.comments.filter { $0.kind.isDoc && !$0.isTrailing }.compactMap { comment in
      guard let decl = Self.declaration(startingWith: comment.anchor), Self.isTrivialPrivate(decl),
        Self.restatesName(comment.body, of: decl)
      else { return nil }
      return RuleViolation(
        path: unit.path, lines: comment.startLine...comment.endLine,
        message: "/// on a trivial private declaration; the name and type already say this")
    }
  }

  private static func declaration(startingWith token: TokenSyntax) -> DeclSyntax? {
    var node = token.parent
    while let current = node {
      if let decl = current.as(DeclSyntax.self) {
        return decl.firstToken(viewMode: .sourceAccurate)?.id == token.id ? decl : nil
      }
      node = current.parent
    }
    return nil
  }

  /// The doc only repeats the declaration's own name (a why-comment on a private constant is
  /// fine).
  private static func restatesName(_ doc: String, of decl: DeclSyntax) -> Bool {
    let nameWords = Set(
      decl.tokens(viewMode: .sourceAccurate).flatMap { token -> [String] in
        guard case .identifier(let text) = token.tokenKind else { return [] }
        return RestatesCodeRule.words(in: text)
      })
    let docWords = RestatesCodeRule.words(in: doc).filter {
      !RestatesCodeRule.stopWords.contains($0)
    }
    guard !docWords.isEmpty, docWords.count <= 6 else { return false }
    return docWords.filter(nameWords.contains).count * 2 >= docWords.count
  }

  private static func isTrivialPrivate(_ decl: DeclSyntax) -> Bool {
    let modifiers: DeclModifierListSyntax
    if let variable = decl.as(VariableDeclSyntax.self) {
      modifiers = variable.modifiers
    } else if let function = decl.as(FunctionDeclSyntax.self),
      (function.body?.statements.count ?? 0) <= 1
    {
      modifiers = function.modifiers
    } else if let alias = decl.as(TypeAliasDeclSyntax.self) {
      modifiers = alias.modifiers
    } else {
      return false
    }
    return modifiers.contains {
      $0.name.tokenKind == .keyword(.private) || $0.name.tokenKind == .keyword(.fileprivate)
    }
  }
}

struct AIProseRule: CommentPatternRule {
  let descriptor = RuleDescriptor(
    id: "comments.ai-prose", severity: .minor,
    summary: "AI-prose tells (it's worth noting, importantly, not X it's Y, em-dash clusters)")

  func matches(in comment: SourceComment, context: RuleContext) -> [(line: Int, message: String)] {
    let patterns: [Regex<Substring>] = [
      /\bit(?:'s|’s| is) worth noting\b/.ignoresCase(),
      /\bimportantly\b/.ignoresCase(),
      /\bnot (?:just |merely |simply )?[^,.;]{1,40}[,;] (?:it(?:'s|’s| is)|but)\b/.ignoresCase(),
    ]
    var lines = Set(patterns.flatMap(comment.matchLines))
    if comment.text.count(where: { $0 == "—" }) >= 2 { lines.insert(comment.startLine) }
    return lines.sorted().map { ($0, "AI-prose tell; say the fact plainly or delete it") }
  }
}

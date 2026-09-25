import SwiftParser
import SwiftSyntax

extension SourceComment {
  private static let directivePrefixes = [
    "swiftgate:", "swiftlint:", "swiftformat:", "periphery:", "sourcery:",
  ]

  /// `// MARK:` and tool directives, which comment-content rules never judge.
  var isExempt: Bool {
    body.hasPrefix("MARK:") || isToolDirective
  }

  var isToolDirective: Bool {
    Self.directivePrefixes.contains { body.hasPrefix($0) }
  }

  /// 1-based line of the UTF-8 offset `offset` within `text`.
  func line(atTextOffset offset: String.Index) -> Int {
    startLine + text[..<offset].count { $0 == "\n" }
  }

  /// Lines of every match of `regex` in the comment's text.
  func matchLines(_ regex: Regex<Substring>) -> [Int] {
    text.matches(of: regex).map { line(atTextOffset: $0.range.lowerBound) }
  }
}

extension SourceUnit {
  /// Runs of own-line `//` comments on consecutive lines, excluding exempt comments. Each run is
  /// what a reader sees as one comment block.
  var lineCommentBlocks: [[SourceComment]] {
    var blocks: [[SourceComment]] = []
    for comment in comments where comment.kind == .line && !comment.isTrailing && !comment.isExempt
    {
      if let last = blocks.last?.last, last.endLine + 1 == comment.startLine {
        blocks[blocks.count - 1].append(comment)
      } else {
        blocks.append([comment])
      }
    }
    return blocks
  }
}

/// Decides whether comment text is Swift code rather than prose: it must parse without errors and
/// contain a construct prose never forms (a declaration, call, assignment, closure, control flow
/// or `try`/`await`). A lone word such as `// Done` parses but is not code.
enum SwiftCodeHeuristic {
  static func isLikelyCode(_ text: String) -> Bool {
    let trimmed = text.trimmed
    guard !trimmed.isEmpty else { return false }
    let tree = Parser.parse(source: trimmed)
    guard !tree.hasError, !tree.statements.isEmpty else { return false }
    if !tree.descendants(of: LabeledStmtSyntax.self).isEmpty { return false }
    for item in tree.statements.map(\.item) {
      if item.is(DeclSyntax.self) { return true }
      if let statement = item.as(StmtSyntax.self), isCodeStatement(statement) { return true }
    }
    return hasCodeExpression(tree)
  }

  private static func isCodeStatement(_ statement: StmtSyntax) -> Bool {
    if let returned = statement.as(ReturnStmtSyntax.self) { return returned.expression != nil }
    return statement.is(GuardStmtSyntax.self) || statement.is(ForStmtSyntax.self)
      || statement.is(WhileStmtSyntax.self) || statement.is(RepeatStmtSyntax.self)
      || statement.is(DoStmtSyntax.self) || statement.is(ThrowStmtSyntax.self)
      || statement.is(DeferStmtSyntax.self)
  }

  private static func hasCodeExpression(_ tree: SourceFileSyntax) -> Bool {
    !tree.descendants(of: FunctionCallExprSyntax.self).isEmpty
      || !tree.descendants(of: ClosureExprSyntax.self).isEmpty
      || !tree.descendants(of: AssignmentExprSyntax.self).isEmpty
      || tree.descendants(of: BinaryOperatorExprSyntax.self).contains {
        isCompoundAssignment($0.operator.text)
      }
      || !tree.descendants(of: TryExprSyntax.self).isEmpty
      || !tree.descendants(of: AwaitExprSyntax.self).isEmpty
      || !tree.descendants(of: IfExprSyntax.self).isEmpty
      || !tree.descendants(of: SwitchExprSyntax.self).isEmpty
  }

  /// Unfolded, `count += 1` is a sequence with a `+=` operator rather than an assignment node.
  /// Comparisons (`<=`, `>=`, `==`, `!=`, `===`, `!==`) also end in `=`, and are prose-safe.
  private static func isCompoundAssignment(_ symbol: String) -> Bool {
    symbol.count >= 2 && symbol.hasSuffix("=")
      && !["<=", ">=", "==", "!=", "===", "!=="].contains(symbol)
  }
}

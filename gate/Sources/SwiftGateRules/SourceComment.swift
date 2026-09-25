import SwiftSyntax

/// One comment from a file's trivia. Comments come only from trivia, so text inside string
/// literals is never mistaken for a comment.
public struct SourceComment: Sendable, Equatable {
  public enum Kind: Sendable, Equatable {
    case line
    case block
    case docLine
    case docBlock

    public var isDoc: Bool { self == .docLine || self == .docBlock }
  }

  public let kind: Kind
  /// The comment exactly as written, markers included.
  public let text: String
  /// Text without comment markers (`//`, `///`, `/*`, `*/`, leading `*`), trimmed.
  public let body: String
  public let startLine: Int
  public let endLine: Int
  /// `true` when the comment follows code on the same line.
  public let isTrailing: Bool
  /// `true` when the comment is followed by a blank line before the next token, so it does not
  /// annotate that token.
  public let isFollowedByBlankLine: Bool
  /// The token the comment trails (if trailing) or precedes (otherwise).
  public let anchor: TokenSyntax

  static func extract(from tree: SourceFileSyntax, converter: SourceLocationConverter)
    -> [SourceComment]
  {
    var comments: [SourceComment] = []
    for token in tree.tokens(viewMode: .sourceAccurate) {
      comments += collect(
        token.leadingTrivia, startingAt: token.position, anchor: token, isTrailing: false,
        converter: converter)
      comments += collect(
        token.trailingTrivia, startingAt: token.endPositionBeforeTrailingTrivia, anchor: token,
        isTrailing: true, converter: converter)
    }
    return comments
  }

  private static func collect(
    _ trivia: Trivia, startingAt start: AbsolutePosition, anchor: TokenSyntax, isTrailing: Bool,
    converter: SourceLocationConverter
  ) -> [SourceComment] {
    var result: [SourceComment] = []
    var offset = start.utf8Offset
    let pieces = Array(trivia)
    for (index, piece) in pieces.enumerated() {
      defer { offset += piece.sourceLength.utf8Length }
      let kind: Kind
      let text: String
      switch piece {
      case .lineComment(let t): (kind, text) = (.line, t)
      case .blockComment(let t): (kind, text) = (.block, t)
      case .docLineComment(let t): (kind, text) = (.docLine, t)
      case .docBlockComment(let t): (kind, text) = (.docBlock, t)
      default: continue
      }
      let length = piece.sourceLength.utf8Length
      let startLine = converter.location(for: AbsolutePosition(utf8Offset: offset)).line
      let endLine = converter.location(
        for: AbsolutePosition(utf8Offset: offset + max(0, length - 1))
      )
      .line
      let newlinesAfter = pieces[(index + 1)...].prefix { !$0.isComment }
        .reduce(0) { $0 + newlineCount($1) }
      result.append(
        SourceComment(
          kind: kind, text: text, body: stripMarkers(text, kind: kind), startLine: startLine,
          endLine: endLine, isTrailing: isTrailing, isFollowedByBlankLine: newlinesAfter >= 2,
          anchor: anchor))
    }
    return result
  }

  private static func newlineCount(_ piece: TriviaPiece) -> Int {
    switch piece {
    case .newlines(let n), .carriageReturns(let n), .carriageReturnLineFeeds(let n): n
    default: 0
    }
  }

  static func stripMarkers(_ text: String, kind: Kind) -> String {
    switch kind {
    case .line: return String(text.dropFirst(2)).trimmed
    case .docLine: return String(text.dropFirst(3)).trimmed
    case .block, .docBlock:
      var inner = Substring(text.dropFirst(kind == .block ? 2 : 3))
      if inner.hasSuffix("*/") { inner = inner.dropLast(2) }
      return inner.split(separator: "\n", omittingEmptySubsequences: false)
        .map { line -> String in
          let trimmed = line.trimmed
          return trimmed.hasPrefix("*") ? String(trimmed.dropFirst()).trimmed : trimmed
        }
        .joined(separator: "\n").trimmed
    }
  }
}

extension StringProtocol {
  var trimmed: String {
    String(
      drop { $0.isWhitespace }.reversed().drop { $0.isWhitespace }.reversed())
  }
}

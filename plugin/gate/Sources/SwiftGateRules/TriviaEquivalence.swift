import SwiftParser
import SwiftSyntax

/// Decides whether an edit to a Swift file changed only trivia: whitespace, line breaks and
/// comments. Such an edit cannot change behavior, so it needs no test change.
public enum TriviaEquivalence {
  /// `true` only when both texts parse cleanly and have the same token sequence. A file that
  /// reads its own source position (`#line`, `#column`, `#sourceLocation`) changes behavior when
  /// whitespace moves, so it never qualifies.
  public static func isTriviaOnlyChange(from old: String, to new: String) -> Bool {
    let oldTree = Parser.parse(source: old)
    let newTree = Parser.parse(source: new)
    guard !oldTree.hasError, !newTree.hasError,
      !readsSourcePosition(oldTree), !readsSourcePosition(newTree)
    else { return false }
    return oldTree.tokens(viewMode: .sourceAccurate).lazy.map(\.tokenKind)
      .elementsEqual(newTree.tokens(viewMode: .sourceAccurate).lazy.map(\.tokenKind))
  }

  private static func readsSourcePosition(_ tree: SourceFileSyntax) -> Bool {
    var previous: TokenKind?
    for token in tree.tokens(viewMode: .sourceAccurate) {
      if token.tokenKind == .poundSourceLocation { return true }
      if previous == .pound,
        token.tokenKind == .identifier("line") || token.tokenKind == .identifier("column")
      {
        return true
      }
      previous = token.tokenKind
    }
    return false
  }
}

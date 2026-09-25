import SwiftGateDomain
import SwiftParser
import SwiftSyntax
import Synchronization

/// A file to check: repository-relative path plus its text (working tree or staged blob).
public struct SourceInput: Sendable, Equatable {
  public let path: String
  public let text: String

  public init(path: String, text: String) {
    self.path = path
    self.text = text
  }
}

/// A parsed file with everything rules share: the syntax tree, its comments, allow directives,
/// imports and module scope. Built once per file per run.
public final class SourceUnit: Sendable {
  public let path: String
  public let scope: ModuleScope?
  public let tree: SourceFileSyntax
  public let comments: [SourceComment]
  public let allowDirectives: [AllowDirective]
  /// Top-level `import` module names, in source order.
  public let imports: [String]
  private let converter: SourceLocationConverter
  private let syntaxIndexCache = Mutex<SyntaxIndex?>(nil)

  public init(input: SourceInput, scope: ModuleScope?) {
    path = input.path
    self.scope = scope
    tree = Parser.parse(source: input.text)
    converter = SourceLocationConverter(fileName: input.path, tree: tree)
    comments = SourceComment.extract(from: tree, converter: converter)
    allowDirectives = comments.compactMap(AllowDirective.init(comment:))
    imports = tree.statements.compactMap {
      $0.item.as(ImportDeclSyntax.self)?.path.first?.name.text
    }
  }

  /// The nodes lint rules match on, collected in one walk the first time any rule asks.
  public var syntaxIndex: SyntaxIndex {
    syntaxIndexCache.withLock { cached in
      if let cached { return cached }
      let index = SyntaxIndex(tree)
      cached = index
      return index
    }
  }

  public var isTestFile: Bool {
    if case .tests = scope?.role { return true }
    return imports.contains { $0 == "Testing" || $0 == "XCTest" }
  }

  public func line(of position: AbsolutePosition) -> Int {
    converter.location(for: position).line
  }

  /// Lines the node's source text spans, excluding surrounding trivia.
  public func lines(of node: some SyntaxProtocol) -> ClosedRange<Int> {
    let start = line(of: node.positionAfterSkippingLeadingTrivia)
    let endOffset = max(
      node.positionAfterSkippingLeadingTrivia.utf8Offset,
      node.endPositionBeforeTrailingTrivia.utf8Offset - 1)
    return start...max(start, line(of: AbsolutePosition(utf8Offset: endOffset)))
  }

  public func violation(
    at node: some SyntaxProtocol, message: String, failureScenario: String? = nil
  ) -> RuleViolation {
    RuleViolation(
      path: path, lines: lines(of: node), message: message, failureScenario: failureScenario)
  }

  /// A violation reported only at the node's first line, for constructs (like whole functions)
  /// whose waiver belongs on their declaration line.
  public func violation(
    atStartOf node: some SyntaxProtocol, message: String, failureScenario: String? = nil
  ) -> RuleViolation {
    let start = line(of: node.positionAfterSkippingLeadingTrivia)
    return RuleViolation(
      path: path, lines: start...start, message: message, failureScenario: failureScenario)
  }

  /// Allow directives on `line` that carry a reason and name `ruleID`.
  public func hasJustifiedAllow(for ruleID: String, onLine line: Int) -> Bool {
    allowDirectives.contains { $0.line == line && $0.ruleID == ruleID && $0.reason != nil }
  }
}

extension SyntaxProtocol {
  /// Every descendant (not including `self`) of type `T`, in source order.
  public func descendants<T: SyntaxProtocol>(of type: T.Type) -> [T] {
    var found: [T] = []
    var stack = Array(children(viewMode: .sourceAccurate).reversed())
    while let node = stack.popLast() {
      if let match = node.as(T.self) { found.append(match) }
      stack.append(contentsOf: node.children(viewMode: .sourceAccurate).reversed())
    }
    return found
  }
}

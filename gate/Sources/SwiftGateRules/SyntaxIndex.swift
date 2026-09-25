import SwiftSyntax

/// The node kinds lint rules match on, gathered in a single traversal so a file is walked once no
/// matter how many rules run over it. Nodes appear in source order.
public final class SyntaxIndex: Sendable {
  public let calls: [FunctionCallExprSyntax]
  public let memberAccesses: [MemberAccessExprSyntax]
  public let references: [DeclReferenceExprSyntax]
  public let typeNames: [IdentifierTypeSyntax]
  public let attributes: [AttributeSyntax]
  /// `try!` expressions only.
  public let forceTries: [TryExprSyntax]
  /// `as!` casts, folded (`AsExprSyntax`) or as the parser leaves them (`UnresolvedAsExprSyntax`).
  public let forceCasts: [Syntax]
  public let modifiers: [DeclModifierSyntax]
  public let imports: [ImportDeclSyntax]

  init(_ tree: SourceFileSyntax) {
    let collector = Collector(viewMode: .sourceAccurate)
    collector.walk(tree)
    calls = collector.calls
    memberAccesses = collector.memberAccesses
    references = collector.references
    typeNames = collector.typeNames
    attributes = collector.attributes
    forceTries = collector.forceTries
    forceCasts = collector.forceCasts
    modifiers = collector.modifiers
    imports = collector.imports
  }

  private final class Collector: SyntaxVisitor {
    var calls: [FunctionCallExprSyntax] = []
    var memberAccesses: [MemberAccessExprSyntax] = []
    var references: [DeclReferenceExprSyntax] = []
    var typeNames: [IdentifierTypeSyntax] = []
    var attributes: [AttributeSyntax] = []
    var forceTries: [TryExprSyntax] = []
    var forceCasts: [Syntax] = []
    var modifiers: [DeclModifierSyntax] = []
    var imports: [ImportDeclSyntax] = []

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
      calls.append(node)
      return .visitChildren
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
      memberAccesses.append(node)
      return .visitChildren
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
      references.append(node)
      return .visitChildren
    }

    override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
      typeNames.append(node)
      return .visitChildren
    }

    override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
      attributes.append(node)
      return .visitChildren
    }

    override func visit(_ node: TryExprSyntax) -> SyntaxVisitorContinueKind {
      if node.questionOrExclamationMark?.tokenKind == .exclamationMark { forceTries.append(node) }
      return .visitChildren
    }

    override func visit(_ node: AsExprSyntax) -> SyntaxVisitorContinueKind {
      if node.questionOrExclamationMark?.tokenKind == .exclamationMark {
        forceCasts.append(Syntax(node))
      }
      return .visitChildren
    }

    override func visit(_ node: UnresolvedAsExprSyntax) -> SyntaxVisitorContinueKind {
      if node.questionOrExclamationMark?.tokenKind == .exclamationMark {
        forceCasts.append(Syntax(node))
      }
      return .visitChildren
    }

    override func visit(_ node: DeclModifierSyntax) -> SyntaxVisitorContinueKind {
      modifiers.append(node)
      return .visitChildren
    }

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
      imports.append(node)
      return .visitChildren
    }
  }
}

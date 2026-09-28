import SwiftGateDomain
import SwiftParser
import SwiftSyntax

/// Reads the targets and products a `Package.swift` declares, with the same parser and
/// `PackageDescription` factory names `surface-check` judges a manifest by. Only literal
/// declarations count: a list the reader can't see whole is unreadable, never empty.
public enum ManifestDeclarationsReader {
  public static func isManifest(_ path: String) -> Bool {
    ManifestDiff.isManifest(path)
  }

  public static func read(_ text: String) -> ManifestReading {
    let tree = Parser.parse(source: text)
    if tree.hasError { return .unreadable("SwiftParser finds a syntax error") }
    let finder = ManifestShape()
    finder.walk(tree)
    guard finder.packageCalls.count == 1, let call = finder.packageCalls.first else {
      return .unreadable(
        finder.packageCalls.isEmpty
          ? "it has no `Package(…)` call" : "it has \(finder.packageCalls.count) `Package(…)` calls"
      )
    }
    if let changed = finder.listsChangedLater.first {
      return .unreadable("`\(changed)` changes a list after `Package(…)`")
    }
    var targets: Set<String> = []
    var products: Set<String> = []
    for argument in call.arguments {
      guard let label = argument.label?.text, label == "targets" || label == "products" else {
        continue
      }
      guard let list = argument.expression.as(ArrayExprSyntax.self) else {
        return .unreadable("`\(label):` isn't an array literal")
      }
      for element in list.elements {
        guard let (factory, name) = declaration(element.expression) else {
          return .unreadable(
            "`\(element.expression.trimmedDescription.prefix(60))` in `\(label):` isn't a "
              + "`.factory(name: \"…\")` call")
        }
        if label == "products" {
          products.insert(name)
        } else if factory != "testTarget" {
          targets.insert(name)
        }
      }
    }
    return .declared(ManifestDeclarations(targets: targets, products: products))
  }

  /// The factory and literal `name:` of a `.target(name: "A", …)`-style element.
  private static func declaration(_ expression: ExprSyntax) -> (String, String)? {
    guard let call = expression.as(FunctionCallExprSyntax.self),
      let member = call.calledExpression.as(MemberAccessExprSyntax.self), member.base == nil,
      ManifestDiff.declarations.contains(member.declName.baseName.text),
      let name = call.arguments.first(where: { $0.label?.text == "name" }),
      let literal = name.expression.as(StringLiteralExprSyntax.self),
      literal.segments.count == 1,
      let segment = literal.segments.first?.as(StringSegmentSyntax.self)
    else { return nil }
    return (member.declName.baseName.text, segment.content.text)
  }
}

/// The `Package(…)` calls in a manifest, and every `x.targets` or `x.products` reached through a
/// value, which can add to a list after the call.
private final class ManifestShape: SyntaxVisitor {
  var packageCalls: [FunctionCallExprSyntax] = []
  var listsChangedLater: [String] = []

  init() { super.init(viewMode: .sourceAccurate) }

  override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
    if node.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == "Package" {
      packageCalls.append(node)
    }
    return .visitChildren
  }

  override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
    let name = node.declName.baseName.text
    if node.base != nil, name == "targets" || name == "products" {
      listsChangedLater.append(node.trimmedDescription)
    }
    return .visitChildren
  }
}

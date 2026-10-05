import SwiftGateDomain
import SwiftSyntax

/// Finds the tests a change adds or edits: test functions whose declaration, attributes included,
/// spans an added line.
public enum ChangedTestDiscovery {
  /// - Parameter target: the test target (module) `unit` belongs to.
  public static func tests(in unit: SourceUnit, target: String, added: AddedLines)
    -> [ChangedTest]
  {
    TestFunction.all(in: unit).compactMap { test in
      let lines = unit.lines(of: test.decl)
      guard added.ranges.contains(where: { $0.overlaps(lines) }) else { return nil }
      switch test.framework {
      case .swiftTesting:
        return ChangedTest(
          framework: .swiftTesting, target: target, suites: suitePath(of: test.decl),
          function: signature(of: test.decl), file: unit.path, line: lines.lowerBound,
          lastLine: lines.upperBound, displayName: test.testAttribute.flatMap(displayName(of:)))
      case .xcTest:
        guard let type = test.enclosingType else { return nil }
        return ChangedTest(
          framework: .xcTest, target: target,
          suites: [String(type.split(separator: ".").last ?? Substring(type))],
          function: test.name, file: unit.path, line: lines.lowerBound,
          lastLine: lines.upperBound)
      }
    }
  }

  /// Whether `unit` declares at least 1 test: a file emptied to its imports holds none, so no run
  /// can select anything from it.
  public static func declaresTests(in unit: SourceUnit) -> Bool {
    !TestFunction.all(in: unit).isEmpty
  }

  /// `name(label:_:)`, the form Swift Testing ids use.
  static func signature(of decl: FunctionDeclSyntax) -> String {
    let labels = decl.signature.parameterClause.parameters.map { "\($0.firstName.text):" }
    return "\(decl.name.text)(\(labels.joined()))"
  }

  /// Enclosing type names, outermost first; an extension contributes its extended type's
  /// components (`extension Outer.Inner` → `Outer`, `Inner`).
  static func suitePath(of decl: FunctionDeclSyntax) -> [String] {
    var path: [String] = []
    var node = decl.parent
    while let current = node {
      if current.is(FunctionDeclSyntax.self) || current.is(ClosureExprSyntax.self) { return [] }
      if let type = current.as(StructDeclSyntax.self) {
        path.insert(type.name.text, at: 0)
      } else if let type = current.as(ClassDeclSyntax.self) {
        path.insert(type.name.text, at: 0)
      } else if let type = current.as(EnumDeclSyntax.self) {
        path.insert(type.name.text, at: 0)
      } else if let type = current.as(ActorDeclSyntax.self) {
        path.insert(type.name.text, at: 0)
      } else if let type = current.as(ExtensionDeclSyntax.self) {
        path.insert(
          contentsOf: type.extendedType.trimmedDescription.split(separator: ".").map(String.init),
          at: 0)
      }
      node = current.parent
    }
    return path
  }

  /// The attribute's first unlabelled string literal: `@Test("name", …)`.
  static func displayName(of attribute: AttributeSyntax) -> String? {
    guard case .argumentList(let arguments) = attribute.arguments,
      let first = arguments.first, first.label == nil,
      let literal = first.expression.as(StringLiteralExprSyntax.self)
    else { return nil }
    return literal.segments.compactMap { $0.as(StringSegmentSyntax.self)?.content.text }.joined()
  }
}

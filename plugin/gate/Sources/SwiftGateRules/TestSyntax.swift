import SwiftSyntax

/// A test function found by syntax: a Swift Testing `@Test` function, or an XCTest `test…` method.
public struct TestFunction: Sendable {
  public enum Framework: Sendable, Equatable {
    case swiftTesting
    case xcTest
  }

  public let decl: FunctionDeclSyntax
  public let framework: Framework
  /// The `@Test` attribute, for Swift Testing functions.
  public let testAttribute: AttributeSyntax?
  /// Name of the enclosing type, if any.
  public let enclosingType: String?

  public var name: String { decl.name.text }
  public var body: CodeBlockSyntax? { decl.body }

  /// Every test function in `unit`. XCTest methods count only in files that import XCTest, inside
  /// a class, with no parameters, so helpers named `test…` elsewhere are not mistaken for tests.
  public static func all(in unit: SourceUnit) -> [TestFunction] {
    let importsXCTest = unit.imports.contains("XCTest")
    return unit.tree.descendants(of: FunctionDeclSyntax.self).compactMap { decl in
      let enclosing = enclosingTypeDecl(of: decl)
      if let attribute = decl.attributes.testAttribute {
        return TestFunction(
          decl: decl, framework: .swiftTesting, testAttribute: attribute,
          enclosingType: enclosing?.name)
      }
      guard importsXCTest, let enclosing, enclosing.isClass,
        decl.name.text.hasPrefix("test"),
        decl.signature.parameterClause.parameters.isEmpty,
        !decl.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) })
      else { return nil }
      return TestFunction(
        decl: decl, framework: .xcTest, testAttribute: nil, enclosingType: enclosing.name)
    }
  }

  private static func enclosingTypeDecl(of decl: FunctionDeclSyntax) -> (
    name: String, isClass: Bool
  )? {
    var node = decl.parent
    while let current = node {
      if let type = current.as(ClassDeclSyntax.self) { return (type.name.text, true) }
      if let type = current.as(StructDeclSyntax.self) { return (type.name.text, false) }
      if let type = current.as(ExtensionDeclSyntax.self) {
        return (type.extendedType.trimmedDescription, false)
      }
      if let type = current.as(ActorDeclSyntax.self) { return (type.name.text, false) }
      if let type = current.as(EnumDeclSyntax.self) { return (type.name.text, false) }
      if current.is(FunctionDeclSyntax.self) || current.is(ClosureExprSyntax.self) { return nil }
      node = current.parent
    }
    return nil
  }
}

extension AttributeListSyntax {
  /// The `@Test` (or `@Testing.Test`) attribute, if present.
  var testAttribute: AttributeSyntax? {
    for element in self {
      guard let attribute = element.as(AttributeSyntax.self) else { continue }
      let name = attribute.attributeName.trimmedDescription
      if name == "Test" || name == "Testing.Test" { return attribute }
    }
    return nil
  }
}

extension SyntaxProtocol {
  /// `true` if `self` lies inside `ancestor`'s subtree.
  func isDescendant(of ancestor: some SyntaxProtocol) -> Bool {
    var node = parent
    while let current = node {
      if current.id == ancestor.id { return true }
      node = current.parent
    }
    return false
  }
}

extension FunctionCallExprSyntax {
  /// The called function's name and, for member calls, the base expression's source text:
  /// `Task.sleep(...)` → (`Task`, `sleep`); `sleep(1)` → (nil, `sleep`).
  var callee: (base: String?, name: String)? {
    if let reference = calledExpression.as(DeclReferenceExprSyntax.self) {
      return (nil, reference.baseName.text)
    }
    if let member = calledExpression.as(MemberAccessExprSyntax.self) {
      return (member.base?.trimmedDescription, member.declName.baseName.text)
    }
    return nil
  }
}

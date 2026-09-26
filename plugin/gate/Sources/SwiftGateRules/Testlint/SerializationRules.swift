import SwiftGateDomain
import SwiftSyntax

/// Testing playbook P6: a Swift Testing test that drives a `TestClock` or calls
/// `withMainSerialExecutor` must sit in a `.serialized` suite. `withMainSerialExecutor` swaps a
/// process-global executor hook and Swift Testing runs tests in parallel by default, so in an
/// unserialized suite one test swaps the hook while another runs and clock-driven tests hang
/// under load.
///
/// Serialization is inherited, so any enclosing suite marked `@Suite(.serialized …)` counts. For a
/// test in an extension, the extended type's declaration must be in the same file; if it is not,
/// the rule cannot see its traits and stays silent rather than guess. XCTest runs a class's tests
/// one at a time, so XCTest methods are not checked.
struct TestClockSerializedRule: FileRule {
  let descriptor = RuleDescriptor(
    id: "test.testclock-serialized", severity: .major,
    summary: "TestClock or withMainSerialExecutor outside a .serialized suite")
  let scope = RuleScope.testFiles

  func check(_ unit: SourceUnit, context: RuleContext) -> [RuleViolation] {
    let serializedTypes = Set(
      unit.tree.descendants(of: DeclSyntax.self).compactMap { decl -> String? in
        guard let (name, attributes) = Self.typeDeclaration(decl),
          Self.isSerializedSuite(attributes)
        else { return nil }
        return name
      })
    let declaredTypes = Set(
      unit.tree.descendants(of: DeclSyntax.self).compactMap { Self.typeDeclaration($0)?.name })

    return TestFunction.all(in: unit).compactMap { test in
      guard test.framework == .swiftTesting, let body = test.body, Self.usesSerialClock(body)
      else { return nil }
      switch Self.serialization(of: test.decl, serialized: serializedTypes, declared: declaredTypes)
      {
      case .serialized, .unknown: return nil
      case .parallel:
        return unit.violation(
          at: test.decl,
          message:
            "test `\(test.name)` drives a TestClock or withMainSerialExecutor in a suite that is "
            + "not `.serialized`; mark the suite `@Suite(.serialized)` so the process-global "
            + "executor hook is not swapped under a parallel test",
          failureScenario: "the suite hangs or flakes when the package's tests run in parallel")
      }
    }
  }

  private enum Serialization {
    case serialized, parallel, unknown
  }

  private static func serialization(
    of decl: FunctionDeclSyntax, serialized: Set<String>, declared: Set<String>
  ) -> Serialization {
    var node = decl.parent
    while let current = node {
      if let (_, attributes) = typeDeclaration(current.as(DeclSyntax.self)) {
        if isSerializedSuite(attributes) { return .serialized }
      } else if let extensionDecl = current.as(ExtensionDeclSyntax.self) {
        let extended = extensionDecl.extendedType.trimmedDescription
        let name = String(extended.split(separator: ".").last ?? Substring(extended))
        if serialized.contains(name) { return .serialized }
        if !declared.contains(name) { return .unknown }
      }
      node = current.parent
    }
    return .parallel
  }

  private static func usesSerialClock(_ body: CodeBlockSyntax) -> Bool {
    body.descendants(of: DeclReferenceExprSyntax.self).contains { reference in
      let name = reference.baseName.text
      return name == "TestClock" || name == "withMainSerialExecutor"
    }
  }

  /// The name and attributes of a struct, class, actor or enum declaration.
  private static func typeDeclaration(_ decl: DeclSyntax?) -> (name: String, AttributeListSyntax)? {
    guard let decl else { return nil }
    if let type = decl.as(StructDeclSyntax.self) { return (type.name.text, type.attributes) }
    if let type = decl.as(ClassDeclSyntax.self) { return (type.name.text, type.attributes) }
    if let type = decl.as(ActorDeclSyntax.self) { return (type.name.text, type.attributes) }
    if let type = decl.as(EnumDeclSyntax.self) { return (type.name.text, type.attributes) }
    return nil
  }

  /// `@Suite(.serialized, …)` in any argument position.
  private static func isSerializedSuite(_ attributes: AttributeListSyntax) -> Bool {
    attributes.contains { element in
      guard let attribute = element.as(AttributeSyntax.self),
        ["Suite", "Testing.Suite"].contains(attribute.attributeName.trimmedDescription),
        case .argumentList(let arguments) = attribute.arguments
      else { return false }
      return arguments.contains { argument in
        argument.expression.as(MemberAccessExprSyntax.self)?.declName.baseName.text
          == "serialized"
      }
    }
  }
}

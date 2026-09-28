import SwiftGateDomain
import SwiftSyntax

/// `swiftgate arch` rules that need source: what a module's files import and declare (spec §6.1).
enum ArchSourceRules {
  static let all: [any Rule] = [
    UIFrameworkInCoreRule(), UndeclaredKindRule(), ClientTestValueRule(), UIHostCompiledRule(),
  ]
}

/// Core and client interfaces must build and test on the host, where UIKit does not exist and
/// SwiftUI drags view code into logic modules.
struct UIFrameworkInCoreRule: FileRule {
  let descriptor = RuleDescriptor(
    id: "arch.ui-framework-in-core", severity: .major,
    summary: "SwiftUI or UIKit imported by a Core module or client interface")
  let scope = RuleScope { unit in
    guard let role = unit.scope?.role, !unit.isTestFile else { return false }
    return role == .core || role == .client
  }

  private static let frameworks: Set<String> = ["SwiftUI", "UIKit"]

  func check(_ unit: SourceUnit, context: RuleContext) -> [RuleViolation] {
    // The index includes imports inside `#if`, which still compile on the platforms that have them.
    unit.syntaxIndex.imports.compactMap { decl in
      guard let name = decl.path.first?.name.text, Self.frameworks.contains(name) else {
        return nil
      }
      return unit.violation(
        at: decl,
        message:
          "\(unit.scope?.module ?? "this module") imports \(name); move views to the UI module",
        failureScenario: "the module stops building under host `swift test`")
    }
  }
}

/// A `feature` Core (the default kind) is a TCA reducer; anything else must be declared in
/// `.swiftgate.toml` with a reason so the choice is reviewed.
struct UndeclaredKindRule: Rule {
  let descriptor = RuleDescriptor(
    id: "arch.undeclared-kind", severity: .major,
    summary: "feature-kind Core module with no @Reducer")
  let scope = RuleScope { unit in
    unit.scope?.role == .core && unit.scope?.kind == .feature && !unit.isTestFile
  }

  func check(_ units: [SourceUnit], context: RuleContext) -> [RuleViolation] {
    let byModule = Dictionary(grouping: units) { $0.scope?.module ?? "" }
    return byModule.keys.sorted().compactMap { module in
      let files = (byModule[module] ?? []).sorted { $0.path < $1.path }
      let hasReducer = files.contains { unit in
        unit.syntaxIndex.attributes.contains { $0.attributeName.trimmedDescription == "Reducer" }
      }
      guard !hasReducer, let first = files.first else { return nil }
      return RuleViolation(
        path: first.path, lines: 1...1,
        message:
          "\(module) is a feature Core but declares no @Reducer; write it as a TCA feature, or "
          + "declare its kind (engine, library, render) in .swiftgate.toml [[modules]] with a reason"
      )
    }
  }
}

/// Every `@DependencyClient` needs an explicit `TestDependencyKey` conformance with `testValue`;
/// otherwise tests fall back to the preview or live value and touch real services.
struct ClientTestValueRule: Rule {
  let descriptor = RuleDescriptor(
    id: "arch.dependency-client-test-value", severity: .major,
    summary: "@DependencyClient without a TestDependencyKey conformance declaring testValue")
  let scope = RuleScope { !$0.isTestFile }

  func check(_ units: [SourceUnit], context: RuleContext) -> [RuleViolation] {
    var clients: [(name: String, unit: SourceUnit, attribute: AttributeSyntax)] = []
    var conformingTypes = Set<String>()
    var typesWithTestValue = Set<String>()
    for unit in units {
      for declaration in unit.tree.descendants(of: DeclSyntax.self) {
        guard let (name, inherited, members, attributes) = Self.typeParts(declaration) else {
          continue
        }
        if let attribute = attributes.first(where: {
          $0.attributeName.trimmedDescription.hasSuffix("DependencyClient")
        }) {
          clients.append((name, unit, attribute))
        }
        if inherited.contains(where: {
          $0 == "TestDependencyKey" || $0.hasSuffix(".TestDependencyKey")
        }) {
          conformingTypes.insert(name)
        }
        if members.contains(where: Self.declaresStaticTestValue) { typesWithTestValue.insert(name) }
      }
    }
    return clients.compactMap { client in
      guard !(conformingTypes.contains(client.name) && typesWithTestValue.contains(client.name))
      else { return nil }
      return client.unit.violation(
        at: client.attribute,
        message:
          "\(client.name) needs `extension \(client.name): TestDependencyKey { static let "
          + "testValue = Self() }` in its interface module",
        failureScenario: "tests resolve the live or preview value and reach real services")
    }
  }

  private static func typeParts(_ declaration: DeclSyntax) -> (
    name: String, inherited: [String], members: MemberBlockItemListSyntax,
    attributes: [AttributeSyntax]
  )? {
    func inherited(_ clause: InheritanceClauseSyntax?) -> [String] {
      clause?.inheritedTypes.map { $0.type.trimmedDescription } ?? []
    }
    func attributes(_ list: AttributeListSyntax) -> [AttributeSyntax] {
      list.compactMap { $0.as(AttributeSyntax.self) }
    }
    if let decl = declaration.as(StructDeclSyntax.self) {
      return (
        decl.name.text, inherited(decl.inheritanceClause), decl.memberBlock.members,
        attributes(decl.attributes)
      )
    }
    if let decl = declaration.as(ExtensionDeclSyntax.self) {
      return (
        decl.extendedType.trimmedDescription, inherited(decl.inheritanceClause),
        decl.memberBlock.members, []
      )
    }
    return nil
  }

  private static func declaresStaticTestValue(_ item: MemberBlockItemSyntax) -> Bool {
    guard let variable = item.decl.as(VariableDeclSyntax.self),
      variable.modifiers.contains(where: { $0.name.text == "static" })
    else { return false }
    return variable.bindings.contains {
      $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == "testValue"
    }
  }
}

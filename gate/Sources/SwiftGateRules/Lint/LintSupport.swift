import SwiftGateDomain
import SwiftSyntax

/// A lint rule defined by what it matches in a file's ``SyntaxIndex``. Matches on the same line
/// collapse to one violation, so a construct spelled two ways on one line is reported once.
struct SyntaxLintRule: FileRule {
  let descriptor: RuleDescriptor
  let scope: RuleScope
  let match: @Sendable (SourceUnit, SyntaxIndex, RuleContext) -> [RuleViolation]

  init(
    id: String, summary: String, scope: RuleScope,
    match: @escaping @Sendable (SourceUnit, SyntaxIndex, RuleContext) -> [RuleViolation]
  ) {
    descriptor = RuleDescriptor(id: id, severity: .major, summary: summary)
    self.scope = scope
    self.match = match
  }

  func check(_ unit: SourceUnit, context: RuleContext) -> [RuleViolation] {
    var seenLines = Set<Int>()
    return match(unit, unit.syntaxIndex, context)
      .filter { seenLines.insert($0.lines.lowerBound).inserted }
      .sorted { $0.lines.lowerBound < $1.lines.lowerBound }
  }
}

enum LintScopes {
  /// Platform-neutral logic and client interfaces: where nondeterminism must be injected.
  static let coreAndInterfaces = RuleScope.roles([.core, .client])

  /// Every classified production module except `*Live` ones. Tests are left out: a Live module's
  /// tests may need the vendor types it wraps.
  static let outsideLive = RuleScope { unit in
    guard let role = unit.scope?.role, !unit.isTestFile else { return false }
    return role != .clientLive
  }

  /// Every classified production module except the log and tracing Live modules, which are the
  /// only places allowed to talk to OSLog and signposts directly.
  static let outsideObservabilityLive = RuleScope { unit in
    guard let scope = unit.scope, !unit.isTestFile else { return false }
    let isObservabilityLive =
      scope.role == .clientLive
      && (scope.module.hasPrefix("Log") || scope.module.hasPrefix("Tracing"))
    return !isObservabilityLive
  }

  static let productionFiles = RuleScope { !$0.isTestFile }
}

/// Modules that may qualify a standard-library or SDK name (`Swift.print`, `Foundation.Date`).
private let qualifyingModules: Set<String> = [
  "Swift", "Foundation", "Dispatch", "Darwin", "os", "OSLog", "ComposableArchitecture",
  "SnapshotTesting",
]

extension ExprSyntax {
  /// `true` for `Name` or a module-qualified `Module.Name`.
  func refersToType(_ name: String) -> Bool {
    if let reference = self.as(DeclReferenceExprSyntax.self) {
      return reference.baseName.text == name
    }
    if let member = self.as(MemberAccessExprSyntax.self),
      let base = member.base?.as(DeclReferenceExprSyntax.self)
    {
      return member.declName.baseName.text == name && qualifyingModules.contains(base.baseName.text)
    }
    if let generic = self.as(GenericSpecializationExprSyntax.self) {
      return generic.expression.refersToType(name)
    }
    return false
  }
}

extension FunctionCallExprSyntax {
  /// `Name(...)`, `Module.Name(...)` or `Name.init(...)`.
  func constructs(_ typeName: String) -> Bool {
    if calledExpression.refersToType(typeName) { return true }
    if let member = calledExpression.as(MemberAccessExprSyntax.self),
      member.declName.baseName.text == "init", let base = member.base
    {
      return base.refersToType(typeName)
    }
    return false
  }

  var hasNoArguments: Bool {
    arguments.isEmpty && trailingClosure == nil && additionalTrailingClosures.isEmpty
  }

  /// A call to a global function: `name(...)` or `Swift.name(...)`, not a method `x.name(...)`.
  func callsFreeFunction(in names: Set<String>) -> Bool {
    if let reference = calledExpression.as(DeclReferenceExprSyntax.self) {
      return names.contains(reference.baseName.text)
    }
    if let member = calledExpression.as(MemberAccessExprSyntax.self),
      let base = member.base?.as(DeclReferenceExprSyntax.self)
    {
      return names.contains(member.declName.baseName.text)
        && qualifyingModules.contains(base.baseName.text)
    }
    return false
  }

  /// The member for `base.name(...)` and implicit `.name(...)` calls.
  var calledMember: MemberAccessExprSyntax? { calledExpression.as(MemberAccessExprSyntax.self) }

  /// The member or function name being called, whatever its base.
  var calledName: String? {
    if let reference = calledExpression.as(DeclReferenceExprSyntax.self) {
      return reference.baseName.text
    }
    return calledMember?.declName.baseName.text
  }

  var argumentLabels: [String?] { arguments.map { $0.label?.text } }
}

extension SourceUnit {
  func imports(_ module: String) -> Bool { imports.contains(module) }
}

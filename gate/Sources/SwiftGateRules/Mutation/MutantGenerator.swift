import SwiftGateDomain
import SwiftSyntax

/// The mutants of one file's added lines, split into those to run and those an
/// `equivalent-mutant` annotation sets aside.
public struct MutationCandidates: Sendable, Equatable {
  public var mutants: [Mutant] = []
  public var equivalent: [EquivalentMutant] = []
  public var bareMarkers: [BareEquivalentMarker] = []

  public init() {}
}

/// `// swiftgate:equivalent-mutant — <reason>`: every mutant on the line the comment starts on is
/// equivalent to the original (no test can tell them apart), so it is not run.
public struct EquivalentMutantDirective: Sendable, Equatable {
  public static let marker = "swiftgate:equivalent-mutant"

  public let line: Int
  public let reason: String?

  init?(comment: SourceComment) {
    guard comment.kind == .line || comment.kind == .block,
      comment.body.hasPrefix(Self.marker)
    else { return nil }
    let rest = comment.body.dropFirst(Self.marker.count)
    guard rest.isEmpty || rest.first?.isWhitespace == true else { return nil }
    var tail = rest.drop { $0.isWhitespace }
    if tail.hasPrefix("—") {
      tail = tail.dropFirst()
    } else if tail.hasPrefix("--") {
      tail = tail.dropFirst(2)
    } else {
      tail = ""
    }
    let reason = tail.trimmed
    line = comment.startLine
    self.reason = reason.isEmpty ? nil : reason
  }
}

/// Generates spec §7.4's mutants on SwiftSyntax. Purely syntactic: no type information, so
/// operators that need a type (return default) act only where the declaration spells it out.
public enum MutantGenerator {
  public static func candidates(in unit: SourceUnit, text: String, added: AddedLines)
    -> MutationCandidates
  {
    let visitor = MutantVisitor(
      unit: unit, text: text, usesTCA: unit.imports.contains("ComposableArchitecture"))
    visitor.walk(unit.tree)
    let directives = unit.comments.compactMap(EquivalentMutantDirective.init(comment:))
    let reasons = Dictionary(
      directives.compactMap { directive in directive.reason.map { (directive.line, $0) } },
      uniquingKeysWith: { first, _ in first })

    var result = MutationCandidates()
    var seen = Set<Mutant>()
    for mutant in visitor.mutants
    where added.contains(line: mutant.line) && seen.insert(mutant).inserted {
      if let reason = reasons[mutant.line] {
        result.equivalent.append(EquivalentMutant(mutant: mutant, reason: reason))
      } else {
        result.mutants.append(mutant)
      }
    }
    result.mutants.sort(by: Mutant.sourceOrder)
    result.bareMarkers = directives.filter { $0.reason == nil && added.contains(line: $0.line) }
      .map { BareEquivalentMarker(file: unit.path, line: $0.line) }
    return result
  }
}

extension AddedLines {
  func contains(line: Int) -> Bool { ranges.contains { $0.contains(line) } }
}

private final class MutantVisitor: SyntaxVisitor {
  private let unit: SourceUnit
  private let text: String
  private let usesTCA: Bool
  private(set) var mutants: [Mutant] = []

  /// Calls whose removal only drops a diagnostic: assertions are not behavior tests can pin.
  private static let diagnosticCalls: Set<String> = [
    "assert", "assertionFailure", "precondition", "preconditionFailure", "fatalError", "print",
    "debugPrint", "dump",
  ]
  private static let effectConstructors: Set<String> = [
    "send", "run", "merge", "concatenate", "publisher",
  ]

  init(unit: SourceUnit, text: String, usesTCA: Bool) {
    self.unit = unit
    self.text = text
    self.usesTCA = usesTCA
    super.init(viewMode: .sourceAccurate)
  }

  // MARK: negate-conditional

  override func visit(_ node: ConditionElementSyntax) -> SyntaxVisitorContinueKind {
    if case .expression(let condition) = node.condition { negate(condition) }
    return .visitChildren
  }

  override func visit(_ node: RepeatStmtSyntax) -> SyntaxVisitorContinueKind {
    negate(node.condition)
    return .visitChildren
  }

  private func negate(_ condition: ExprSyntax) {
    // `while true` negated leaves a function without a return: it never compiles.
    if condition.is(BooleanLiteralExprSyntax.self) { return }
    if let prefix = condition.as(PrefixOperatorExprSyntax.self), prefix.operator.text == "!" {
      add(.negateConditional, condition, source(of: prefix.expression))
    } else {
      add(.negateConditional, condition, "!(\(source(of: condition)))")
    }
  }

  // MARK: relational-boundary

  override func visit(_ node: BinaryOperatorExprSyntax) -> SyntaxVisitorContinueKind {
    let swapped = ["<": "<=", "<=": "<", ">": ">=", ">=": ">"]
    if let replacement = swapped[node.operator.text] {
      add(.relationalBoundary, node, replacement)
    }
    return .visitChildren
  }

  // MARK: return-default and remove-effect on returned values

  override func visit(_ node: ReturnStmtSyntax) -> SyntaxVisitorContinueKind {
    if let value = node.expression { returned(value, owner: Owner.of(Syntax(node))) }
    return .visitChildren
  }

  override func visit(_ node: CodeBlockItemListSyntax) -> SyntaxVisitorContinueKind {
    // A single-expression body returns its expression implicitly.
    if node.count == 1, let item = node.first, case .expr(let value) = item.item {
      let owner = Owner.of(bodyList: node)
      if case .declaration = owner { returned(value, owner: owner) }
    }
    return .visitChildren
  }

  private func returned(_ value: ExprSyntax, owner: Owner) {
    if usesTCA, let root = effectConstructor(value), root != "none" {
      add(.removeEffect, value, ".none")
      return
    }
    guard case .declaration(let type?) = owner,
      let replacement = Self.defaultValue(for: type, replacing: source(of: value))
    else { return }
    add(.returnDefault, value, replacement)
  }

  /// `.send(…)`, `.run { … }.cancellable(id:)`, `Effect.merge(…)`: the implicit-member name the
  /// expression's member chain starts from.
  private func effectConstructor(_ expression: ExprSyntax) -> String? {
    var current = expression
    var name: String?
    while true {
      if let call = current.as(FunctionCallExprSyntax.self) {
        current = call.calledExpression
      } else if let member = current.as(MemberAccessExprSyntax.self) {
        name = member.declName.baseName.text
        guard let base = member.base else { break }
        if let reference = base.as(DeclReferenceExprSyntax.self),
          ["Effect", "EffectOf"].contains(reference.baseName.text)
        {
          break
        }
        current = base
      } else {
        return nil
      }
    }
    guard let name, Self.effectConstructors.contains(name) || name == "none" else { return nil }
    return name
  }

  private static func defaultValue(for type: TypeSyntax, replacing value: String) -> String? {
    let defaultText: String
    if type.is(OptionalTypeSyntax.self) || type.is(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
      defaultText = "nil"
    } else if type.is(ArrayTypeSyntax.self) {
      defaultText = "[]"
    } else if type.is(DictionaryTypeSyntax.self) {
      defaultText = "[:]"
    } else if let identifier = type.as(IdentifierTypeSyntax.self) {
      switch identifier.name.text {
      case "Bool": return value == "false" ? "true" : "false"
      case "String", "Substring": defaultText = "\"\""
      case "Optional": defaultText = "nil"
      case "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32",
        "UInt64", "Double", "Float", "Float16", "CGFloat", "Decimal", "TimeInterval":
        defaultText = "0"
      default: return nil
      }
    } else {
      return nil
    }
    return value == defaultText ? nil : defaultText
  }

  // MARK: remove-call and remove-effect on statements

  override func visit(_ node: CodeBlockItemSyntax) -> SyntaxVisitorContinueKind {
    guard case .expr(let expression) = node.item,
      let call = Self.unwrapped(expression).as(FunctionCallExprSyntax.self),
      let name = Self.calledName(call),
      !Self.diagnosticCalls.contains(name), name != "init"
    else { return .visitChildren }
    guard let list = node.parent?.as(CodeBlockItemListSyntax.self) else { return .visitChildren }
    let isSend =
      usesTCA && call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == "send"
    // A TCA `send` returns nothing, so even as a closure's only statement it is no implicit return.
    if list.count == 1, !isSend {
      switch Owner.of(bodyList: list) {
      case .closure, .declaration(.some): return .visitChildren  // an implicit return
      case .declaration(nil), .other: break
      }
    }
    let replacement =
      list.count == 1 && list.parent?.is(SwitchCaseSyntax.self) == true
      ? "break" : ""
    add(isSend ? .removeEffect : .removeCall, node, replacement)
    return .visitChildren
  }

  private static func unwrapped(_ expression: ExprSyntax) -> ExprSyntax {
    var current = expression
    while true {
      if let tried = current.as(TryExprSyntax.self) {
        current = tried.expression
      } else if let awaited = current.as(AwaitExprSyntax.self) {
        current = awaited.expression
      } else {
        return current
      }
    }
  }

  private static func calledName(_ call: FunctionCallExprSyntax) -> String? {
    if let reference = call.calledExpression.as(DeclReferenceExprSyntax.self) {
      return reference.baseName.text
    }
    return call.calledExpression.as(MemberAccessExprSyntax.self)?.declName.baseName.text
  }

  // MARK: Emitting

  private func source(of node: some SyntaxProtocol) -> String {
    let start = node.positionAfterSkippingLeadingTrivia.utf8Offset
    let end = node.endPositionBeforeTrailingTrivia.utf8Offset
    let bytes = text.utf8
    let lower = bytes.index(bytes.startIndex, offsetBy: start)
    let upper = bytes.index(lower, offsetBy: max(0, end - start))
    return String(decoding: bytes[lower..<upper], as: UTF8.self)
  }

  private func add(
    _ mutationOperator: MutationOperator, _ node: some SyntaxProtocol, _ replacement: String
  ) {
    let original = source(of: node)
    guard original != replacement,
      let mutant = Mutant(
        file: unit.path, text: text,
        utf8Offset: node.positionAfterSkippingLeadingTrivia.utf8Offset, original: original,
        replacement: replacement, operator: mutationOperator)
    else { return }
    mutants.append(mutant)
  }
}

/// What a `return` (or a single-expression body) returns from.
private enum Owner {
  case closure
  /// A function, accessor, subscript or property with its declared type, `nil` when it returns
  /// `Void` or does not spell its type out.
  case declaration(TypeSyntax?)
  /// A block that is not a body (an `if` branch, a loop, a switch case).
  case other

  static func of(_ node: Syntax) -> Owner {
    var current = node.parent
    while let node = current {
      if let owner = declared(node) { return owner }
      current = node.parent
    }
    return .declaration(nil)
  }

  /// The owner of a statement list when the list is itself a body.
  static func of(bodyList list: CodeBlockItemListSyntax) -> Owner {
    guard let parent = list.parent else { return .other }
    if parent.is(ClosureExprSyntax.self) { return .closure }
    if parent.is(AccessorBlockSyntax.self) { return of(parent) }
    guard parent.is(CodeBlockSyntax.self), let owner = parent.parent else { return .other }
    if let getter = owner.as(AccessorDeclSyntax.self), getter.accessorSpecifier.text == "get" {
      return of(owner)
    }
    return declared(owner) ?? .other
  }

  private static func declared(_ node: Syntax) -> Owner? {
    if node.is(ClosureExprSyntax.self) { return .closure }
    if let function = node.as(FunctionDeclSyntax.self) {
      return .declaration(function.signature.returnClause?.type)
    }
    if node.is(InitializerDeclSyntax.self) || node.is(DeinitializerDeclSyntax.self) {
      return .declaration(nil)
    }
    if let subscriptDecl = node.as(SubscriptDeclSyntax.self) {
      return .declaration(subscriptDecl.returnClause.type)
    }
    if let accessor = node.as(AccessorDeclSyntax.self), accessor.accessorSpecifier.text != "get" {
      return .declaration(nil)
    }
    if let binding = node.as(PatternBindingSyntax.self) {
      return .declaration(binding.typeAnnotation?.type)
    }
    return nil
  }
}

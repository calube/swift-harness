import SwiftGateDomain
import SwiftParser
import SwiftSyntax

/// The functions and types a commit's parent declares, which a forwarding stub may call.
public struct SurfaceParentIndex: Sendable, Equatable {
  /// Function names, and property names too, since a forward may call a closure property (a TCA
  /// dependency client's endpoints are closures).
  public let functions: Set<String>
  public let types: Set<String>

  public init(functions: Set<String>, types: Set<String>) {
    self.functions = functions
    self.types = types
  }

  public static func build(_ sources: [String: String]) -> SurfaceParentIndex {
    let collector = DeclaredNames()
    for text in sources.values { collector.walk(Parser.parse(source: text)) }
    return SurfaceParentIndex(functions: collector.functions, types: collector.types)
  }
}

private final class DeclaredNames: SyntaxVisitor {
  var functions: Set<String> = []
  var types: Set<String> = []

  init() { super.init(viewMode: .sourceAccurate) }

  override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
    functions.insert(node.name.text)
    return .skipChildren
  }
  override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
    for binding in node.bindings {
      if let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text {
        functions.insert(name)
      }
    }
    return .skipChildren
  }
  override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
    types.insert(node.name.text)
    return .visitChildren
  }
  override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
    types.insert(node.name.text)
    return .visitChildren
  }
  override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
    types.insert(node.name.text)
    return .visitChildren
  }
  override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
    types.insert(node.name.text)
    return .visitChildren
  }
  override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
    types.insert(node.name.text)
    return .skipChildren
  }
}

/// The SwiftSyntax half of `surface-check`: finds the bodies a change adds or changes and judges
/// each against the allowed stubs (fast modes §3.2).
public enum SurfaceBodyScan {
  /// The callees of every body shaped like a forwarding call, so the parent's declarations are
  /// read only when a body could forward.
  public static func forwardCallees(in change: SurfaceFileChange) -> Set<String> {
    let asked = CalleeLog()
    _ = scan(change) { name, _ in
      asked.names.insert(name)
      return false
    }
    return asked.names
  }

  public static func judge(_ change: SurfaceFileChange, parent: SurfaceParentIndex)
    -> [SurfaceJudgement]
  {
    scan(change) { name, isType in
      isType ? parent.types.contains(name) : parent.functions.contains(name)
    }
  }

  private final class CalleeLog {
    var names: Set<String> = []
  }

  private static func scan(
    _ change: SurfaceFileChange, declares: @escaping (String, Bool) -> Bool
  ) -> [SurfaceJudgement] {
    guard let text = change.commitText else { return [] }
    let tree = Parser.parse(source: text)
    let after = BodyCollector(converter: SourceLocationConverter(fileName: change.path, tree: tree))
    after.walk(tree)
    var before: [String: [BodyUnit]] = [:]
    if let parentText = change.parentText {
      let parentTree = Parser.parse(source: parentText)
      let collector = BodyCollector(
        converter: SourceLocationConverter(fileName: change.path, tree: parentTree))
      collector.walk(parentTree)
      before = Dictionary(grouping: collector.units, by: \.key)
    }
    let isTestFile = SurfaceCheck.isTestFile(change.path)
    var judgements: [SurfaceJudgement] = []
    for unit in after.units {
      let candidates = before[unit.key] ?? []
      if candidates.contains(where: { $0.normalized == unit.normalized }) { continue }
      func add(_ outcome: SurfaceJudgement.Outcome, _ declaration: String, _ line: Int) {
        judgements.append(
          SurfaceJudgement(
            file: change.path, line: line, declaration: declaration, outcome: outcome))
      }
      let judge = Judge(enclosingType: unit.enclosingType, declares: declares)
      switch unit.kind {
      case .storedValue:
        // An added stored property is surface (§3.1); only a changed existing value is judged.
        if !candidates.isEmpty {
          add(.behaviour(.changesStoredValue), unit.declaration, unit.line)
        }
      case .previewValue(let expression):
        add(judge.preview(Syntax(expression)), unit.declaration, unit.line)
      case .body(let items):
        if isTestFile, unit.isTest, candidates.isEmpty {
          add(.behaviour(.addsTest), unit.declaration, unit.line)
          continue
        }
        if let clauses = candidates.lazy.compactMap({ addedClauses(unit, over: $0) }).first {
          for clause in clauses {
            add(
              judge.clause(clause.statements, context: unit.context),
              "\(unit.declaration) \(clauseName(clause))",
              after.line(of: Syntax(clause)))
          }
        } else {
          add(judge.body(items, context: unit.context), unit.declaration, unit.line)
        }
      }
    }
    return judgements
  }

  /// The switch cases `unit` adds over `previous` when they are its only change, so adding an enum
  /// case and its stub branch doesn't make the whole existing body look new.
  private static func addedClauses(_ unit: BodyUnit, over previous: BodyUnit) -> [SwitchCaseSyntax]?
  {
    let known = Set(previous.node.switchCases.map { normalize(Syntax($0)) })
    let fresh = unit.node.switchCases.filter { !known.contains(normalize(Syntax($0))) }
    let outermost = fresh.filter { clause in
      !fresh.contains { other in
        other.id != clause.id && other.position <= clause.position
          && clause.endPosition <= other.endPosition
      }
    }
    guard !outermost.isEmpty else { return nil }
    let remaining = unit.node.tokens(viewMode: .sourceAccurate).filter { token in
      !outermost.contains { $0.position <= token.position && token.endPosition <= $0.endPosition }
    }
    guard remaining.map(\.text).joined(separator: " ") == previous.normalized else { return nil }
    return outermost
  }

  private static func clauseName(_ clause: SwitchCaseSyntax) -> String {
    switch clause.label {
    case .case(let label): "case \(label.caseItems.trimmedDescription)"
    case .default: "default"
    }
  }

  static func normalize(_ node: Syntax) -> String {
    node.tokens(viewMode: .sourceAccurate).map(\.text).joined(separator: " ")
  }
}

/// Where a body sits, which picks the stub rules it's held to.
private enum BodyContext {
  case function
  case view
  case reducer
  case preview
}

private struct BodyUnit {
  enum Kind {
    case body(CodeBlockItemListSyntax)
    case previewValue(ExprSyntax)
    /// A stored property's initial value, closures excluded: they're judged as bodies.
    case storedValue
  }

  let key: String
  let declaration: String
  let line: Int
  let context: BodyContext
  let kind: Kind
  let node: Syntax
  let normalized: String
  let enclosingType: String?
  let isTest: Bool
}

extension Syntax {
  fileprivate var switchCases: [SwitchCaseSyntax] {
    final class Finder: SyntaxVisitor {
      var found: [SwitchCaseSyntax] = []
      override func visit(_ node: SwitchCaseSyntax) -> SyntaxVisitorContinueKind {
        found.append(node)
        return .visitChildren
      }
    }
    let finder = Finder(viewMode: .sourceAccurate)
    finder.walk(self)
    return finder.found
  }
}

/// Every judgeable body in a file, keyed by enclosing types and declaration so each can be
/// matched with the same declaration on the parent.
private final class BodyCollector: SyntaxVisitor {
  private let converter: SourceLocationConverter
  private var containers: [String] = []
  private var previewCount = 0
  var units: [BodyUnit] = []

  init(converter: SourceLocationConverter) {
    self.converter = converter
    super.init(viewMode: .sourceAccurate)
  }

  func line(of node: Syntax) -> Int {
    converter.location(for: node.positionAfterSkippingLeadingTrivia).line
  }

  override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
    push(node.name.text)
  }
  override func visitPost(_ node: StructDeclSyntax) { containers.removeLast() }
  override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
    push(node.name.text)
  }
  override func visitPost(_ node: ClassDeclSyntax) { containers.removeLast() }
  override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { push(node.name.text) }
  override func visitPost(_ node: EnumDeclSyntax) { containers.removeLast() }
  override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
    push(node.name.text)
  }
  override func visitPost(_ node: ActorDeclSyntax) { containers.removeLast() }
  override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
    push(node.name.text)
  }
  override func visitPost(_ node: ProtocolDeclSyntax) { containers.removeLast() }
  override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
    push(node.extendedType.trimmedDescription)
  }
  override func visitPost(_ node: ExtensionDeclSyntax) { containers.removeLast() }

  private func push(_ name: String) -> SyntaxVisitorContinueKind {
    containers.append(name)
    return .visitChildren
  }

  override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
    if let body = node.body {
      let isTest = node.attributes.contains {
        $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "Test"
      }
      add(
        key: "func \(node.name.text)",
        name: "\(node.name.text)(\(labels(node.signature.parameterClause.parameters)))",
        at: Syntax(node), context: .function, kind: .body(body.statements), node: Syntax(body),
        isTest: isTest || node.name.text.hasPrefix("test"))
    }
    return .skipChildren
  }

  override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
    if let body = node.body {
      add(
        key: "init", name: "init(\(labels(node.signature.parameterClause.parameters)))",
        at: Syntax(node), context: .function, kind: .body(body.statements), node: Syntax(body))
    }
    return .skipChildren
  }

  override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
    if let body = node.body {
      add(
        key: "deinit", name: "deinit", at: Syntax(node), context: .function,
        kind: .body(body.statements), node: Syntax(body))
    }
    return .skipChildren
  }

  override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
    if let block = node.accessorBlock {
      accessors(
        block, key: "subscript", name: "subscript(\(labels(node.parameterClause.parameters)))",
        at: Syntax(node), context: .function)
    }
    return .skipChildren
  }

  override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
    for binding in node.bindings {
      guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else {
        continue
      }
      let type = binding.typeAnnotation?.type.trimmedDescription ?? ""
      let isPreview = Self.isPreviewName(name)
      let context: BodyContext =
        if type.contains("Reducer") { .reducer } else if name == "body" && type.contains("View") {
          .view
        } else if isPreview { .preview } else { .function }
      if let block = binding.accessorBlock {
        accessors(block, key: "var \(name)", name: name, at: Syntax(node), context: context)
      }
      guard let value = binding.initializer?.value else { continue }
      if isPreview {
        add(
          key: "var \(name).value", name: name, at: Syntax(node), context: .preview,
          kind: .previewValue(value), node: Syntax(value))
        continue
      }
      let closures = Self.outermostClosures(in: Syntax(value))
      for (index, closure) in closures.enumerated() {
        add(
          key: "var \(name).closure\(index)",
          name: closures.count == 1 ? name : "\(name) closure \(index + 1)", at: Syntax(node),
          context: .function, kind: .body(closure.statements), node: Syntax(closure))
      }
      let masked = value.tokens(viewMode: .sourceAccurate).filter { token in
        !closures.contains { $0.position <= token.position && token.endPosition <= $0.endPosition }
      }
      units.append(
        BodyUnit(
          key: containerKey("var \(name).value"), declaration: qualified(name),
          line: line(of: Syntax(node)), context: .function, kind: .storedValue, node: Syntax(value),
          normalized: masked.map(\.text).joined(separator: " "), enclosingType: containers.last,
          isTest: false))
    }
    return .skipChildren
  }

  override func visit(_ node: MacroExpansionDeclSyntax) -> SyntaxVisitorContinueKind {
    preview(
      name: node.macroName.text, arguments: node.arguments, closure: node.trailingClosure,
      at: Syntax(node))
    return .skipChildren
  }

  override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
    preview(
      name: node.macroName.text, arguments: node.arguments, closure: node.trailingClosure,
      at: Syntax(node))
    return .skipChildren
  }

  private func preview(
    name: String, arguments: LabeledExprListSyntax, closure: ClosureExprSyntax?, at node: Syntax
  ) {
    guard name == "Preview", let closure else { return }
    let label = arguments.isEmpty ? "#Preview" : "#Preview(\(arguments.trimmedDescription))"
    add(
      key: "\(label)", name: label, at: node, context: .preview, kind: .body(closure.statements),
      node: Syntax(closure), qualify: false)
  }

  private func accessors(
    _ block: AccessorBlockSyntax, key: String, name: String, at node: Syntax,
    context: BodyContext
  ) {
    switch block.accessors {
    case .getter(let items):
      add(
        key: key, name: name, at: node, context: context, kind: .body(items), node: Syntax(items))
    case .accessors(let list):
      for accessor in list {
        guard let body = accessor.body else { continue }
        let specifier = accessor.accessorSpecifier.text
        add(
          key: "\(key).\(specifier)", name: "\(name).\(specifier)", at: Syntax(accessor),
          context: specifier == "get" ? context : .function, kind: .body(body.statements),
          node: Syntax(body))
      }
    }
  }

  private func add(
    key: String, name: String, at declaration: Syntax, context: BodyContext, kind: BodyUnit.Kind,
    node: Syntax, isTest: Bool = false, qualify: Bool = true
  ) {
    units.append(
      BodyUnit(
        key: qualify ? containerKey(key) : "\(key)#\(previewIndex())",
        declaration: qualify ? qualified(name) : name, line: line(of: declaration),
        context: context, kind: kind, node: node, normalized: SurfaceBodyScan.normalize(node),
        enclosingType: containers.last, isTest: isTest))
  }

  private func previewIndex() -> Int {
    previewCount += 1
    return previewCount
  }

  private func containerKey(_ key: String) -> String {
    (containers + [key]).joined(separator: "|")
  }

  private func qualified(_ name: String) -> String {
    (containers + [name]).joined(separator: ".")
  }

  private func labels(_ parameters: FunctionParameterListSyntax) -> String {
    parameters.map { "\($0.firstName.text):" }.joined()
  }

  static func isPreviewName(_ name: String) -> Bool {
    let lowered = name.lowercased()
    return ["preview", "sample", "mock"].contains { lowered.hasPrefix($0) }
  }

  static func outermostClosures(in node: Syntax) -> [ClosureExprSyntax] {
    final class Finder: SyntaxVisitor {
      var found: [ClosureExprSyntax] = []
      override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        found.append(node)
        return .skipChildren
      }
    }
    let finder = Finder(viewMode: .sourceAccurate)
    finder.walk(node)
    return finder.found
  }
}

/// The §3.2 table: the stub rules a body is held to in its context.
private struct Judge {
  let enclosingType: String?
  let declares: (String, Bool) -> Bool

  static let traps: Set<String> = ["fatalError", "preconditionFailure"]

  func body(_ items: CodeBlockItemListSyntax, context: BodyContext) -> SurfaceJudgement.Outcome {
    if let trap = Self.firstTrap(in: Syntax(items)) { return .behaviour(.traps(callee: trap)) }
    switch context {
    case .function: return stub(items)
    case .preview: return preview(Syntax(items))
    case .view:
      guard !items.isEmpty else { return .stub(.empty) }
      if items.count == 1, let value = Self.value(of: items.first!), Self.isEmptyViewTree(value) {
        return .stub(.emptyView)
      }
      return .behaviour(.viewContent(excerpt: Self.excerpt(items.first!)))
    case .reducer:
      guard !items.isEmpty else { return .stub(.empty) }
      for item in items {
        guard let offending = Self.reducerWork(in: item) else { continue }
        return .behaviour(.reducerWork(excerpt: offending))
      }
      return .stub(.reducerNone)
    }
  }

  /// A switch case the change adds to an existing body: in a reducer it returns `.none`; anywhere
  /// else it is held to the body rules of its context.
  func clause(_ items: CodeBlockItemListSyntax, context: BodyContext) -> SurfaceJudgement.Outcome {
    guard context == .reducer else { return body(items, context: context) }
    if let trap = Self.firstTrap(in: Syntax(items)) { return .behaviour(.traps(callee: trap)) }
    if let offending = Self.reducerWork(statements: items) {
      return .behaviour(.reducerWork(excerpt: offending))
    }
    return .stub(.reducerNone)
  }

  func preview(_ node: Syntax) -> SurfaceJudgement.Outcome {
    if let trap = Self.firstTrap(in: node) { return .behaviour(.traps(callee: trap)) }
    if let literal = Self.firstNonEmptyLiteral(in: node) {
      return .behaviour(.sampleData(literal: literal))
    }
    return .stub(.previewWithoutData)
  }

  private func stub(_ items: CodeBlockItemListSyntax) -> SurfaceJudgement.Outcome {
    guard let first = items.first else { return .stub(.empty) }
    guard items.count == 1 else { return .behaviour(.notAStub(excerpt: Self.excerpt(first))) }
    if let returned = first.item.as(ReturnStmtSyntax.self), returned.expression == nil {
      return .stub(.empty)
    }
    if let value = Self.value(of: first), let outcome = judgeValue(value) { return outcome }
    return .behaviour(.notAStub(excerpt: Self.excerpt(first)))
  }

  private func judgeValue(_ expression: ExprSyntax) -> SurfaceJudgement.Outcome? {
    let value = Self.unwrapped(expression)
    if Self.isEmptyDefault(value) { return .stub(.emptyDefault) }
    if Self.isPayloadFreeCase(value) { return .stub(.payloadFreeCase) }
    if let call = value.as(FunctionCallExprSyntax.self) { return forward(call) }
    return nil
  }

  /// A forward: 1 call with no trailing closure, passing only names and empty defaults, to a
  /// function or type the parent declares.
  private func forward(_ call: FunctionCallExprSyntax) -> SurfaceJudgement.Outcome? {
    guard call.trailingClosure == nil, call.additionalTrailingClosures.isEmpty,
      call.arguments.allSatisfy({ Self.isPlain($0.expression) })
    else { return nil }
    let callee: String
    var base: ExprSyntax?
    if let reference = call.calledExpression.as(DeclReferenceExprSyntax.self) {
      callee = reference.baseName.text
    } else if let member = call.calledExpression.as(MemberAccessExprSyntax.self),
      let memberBase = member.base, Self.isPlain(memberBase)
    {
      callee = member.declName.baseName.text
      base = memberBase
    } else {
      return nil
    }
    let name: String
    let isType: Bool
    if callee == "init" {
      let baseName = base?.trimmedDescription
      guard let type = baseName == "self" || baseName == "super" ? enclosingType : baseName
      else { return nil }
      name = type.split(separator: ".").last.map(String.init) ?? type
      isType = true
    } else {
      name = callee
      isType = callee.first?.isUppercase == true
    }
    return declares(name, isType) ? .stub(.forward) : .behaviour(.forwardsToNewCode(callee: name))
  }

  private static func value(of item: CodeBlockItemSyntax) -> ExprSyntax? {
    switch item.item {
    case .expr(let expression): return expression
    case .stmt(let statement):
      if let returned = statement.as(ReturnStmtSyntax.self) { return returned.expression }
      return statement.as(ExpressionStmtSyntax.self)?.expression
    case .decl: return nil
    }
  }

  private static func unwrapped(_ expression: ExprSyntax) -> ExprSyntax {
    if let tried = expression.as(TryExprSyntax.self) { return unwrapped(tried.expression) }
    if let awaited = expression.as(AwaitExprSyntax.self) { return unwrapped(awaited.expression) }
    return expression
  }

  /// §7's closed list: `nil`, `[]`, `[:]`, `0`, `false`, `""`, `.init()`.
  private static func isEmptyDefault(_ value: ExprSyntax) -> Bool {
    if value.is(NilLiteralExprSyntax.self) { return true }
    if let array = value.as(ArrayExprSyntax.self) { return array.elements.isEmpty }
    if let dictionary = value.as(DictionaryExprSyntax.self) {
      if case .colon = dictionary.content { return true }
      return false
    }
    if let integer = value.as(IntegerLiteralExprSyntax.self) { return integer.literal.text == "0" }
    if let boolean = value.as(BooleanLiteralExprSyntax.self) {
      return boolean.literal.tokenKind == .keyword(.false)
    }
    if let string = value.as(StringLiteralExprSyntax.self) { return isEmptyString(string) }
    if let call = value.as(FunctionCallExprSyntax.self),
      let member = call.calledExpression.as(MemberAccessExprSyntax.self)
    {
      return member.base == nil && member.declName.baseName.text == "init"
        && call.arguments.isEmpty && call.trailingClosure == nil
        && call.additionalTrailingClosures.isEmpty
    }
    return false
  }

  private static func isEmptyString(_ string: StringLiteralExprSyntax) -> Bool {
    string.segments.allSatisfy { segment in
      if case .stringSegment(let text) = segment { return text.content.text.isEmpty }
      return false
    }
  }

  private static func isPayloadFreeCase(_ value: ExprSyntax) -> Bool {
    guard let member = value.as(MemberAccessExprSyntax.self) else { return false }
    return member.base == nil && member.declName.argumentNames == nil
  }

  /// A name, a member of a name, or an empty default: an argument a forward may pass on.
  private static func isPlain(_ expression: ExprSyntax) -> Bool {
    if expression.is(DeclReferenceExprSyntax.self) || expression.is(SuperExprSyntax.self) {
      return true
    }
    if let member = expression.as(MemberAccessExprSyntax.self), let base = member.base {
      return isPlain(base)
    }
    if let passed = expression.as(InOutExprSyntax.self) { return isPlain(passed.expression) }
    return isEmptyDefault(expression) || isPayloadFreeCase(expression)
  }

  private static func isEmptyViewTree(_ expression: ExprSyntax) -> Bool {
    guard let call = expression.as(FunctionCallExprSyntax.self),
      let callee = call.calledExpression.as(DeclReferenceExprSyntax.self),
      call.arguments.isEmpty, call.additionalTrailingClosures.isEmpty
    else { return false }
    guard let closure = call.trailingClosure else { return callee.baseName.text == "EmptyView" }
    return callee.baseName.text != "EmptyView" && !closure.statements.isEmpty
      && closure.statements.allSatisfy { item in value(of: item).map(isEmptyViewTree) ?? false }
  }

  /// The first statement of `item` that does more than return `.none`, or `nil` when every path
  /// returns `.none`.
  private static func reducerWork(in item: CodeBlockItemSyntax) -> String? {
    guard let call = value(of: item)?.as(FunctionCallExprSyntax.self),
      let callee = call.calledExpression.as(DeclReferenceExprSyntax.self)
    else { return excerpt(item) }
    switch callee.baseName.text {
    case "EmptyReducer" where call.arguments.isEmpty && call.trailingClosure == nil:
      return nil
    case "Reduce":
      let closure =
        call.trailingClosure
        ?? (call.arguments.count == 1
          ? call.arguments.first?.expression.as(ClosureExprSyntax.self)
          : nil)
      guard let closure, call.additionalTrailingClosures.isEmpty else { return excerpt(item) }
      return reducerWork(statements: closure.statements)
    default:
      return excerpt(item)
    }
  }

  static func reducerWork(statements: CodeBlockItemListSyntax) -> String? {
    if statements.count == 1, let only = statements.first {
      if returnsNone(only) { return nil }
      if let switched = value(of: only)?.as(SwitchExprSyntax.self) {
        for element in switched.cases {
          guard case .switchCase(let clause) = element else { return excerpt(only) }
          if let offending = reducerWork(statements: clause.statements) { return offending }
        }
        return nil
      }
    }
    return (statements.first { !returnsNone($0) } ?? statements.first).map(excerpt) ?? ""
  }

  private static func returnsNone(_ item: CodeBlockItemSyntax) -> Bool {
    guard let member = value(of: item)?.as(MemberAccessExprSyntax.self) else { return false }
    return member.base == nil && member.declName.baseName.text == "none"
  }

  static func firstTrap(in node: Syntax) -> String? {
    final class Finder: SyntaxVisitor {
      var found: String?
      override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if found == nil, let callee = node.calledExpression.as(DeclReferenceExprSyntax.self),
          Judge.traps.contains(callee.baseName.text)
        {
          found = callee.baseName.text
        }
        return found == nil ? .visitChildren : .skipChildren
      }
    }
    let finder = Finder(viewMode: .sourceAccurate)
    finder.walk(node)
    return finder.found
  }

  /// The first literal that holds a value: a non-empty string, a non-zero number, `true`, a
  /// non-empty collection or a regex.
  static func firstNonEmptyLiteral(in node: Syntax) -> String? {
    final class Finder: SyntaxAnyVisitor {
      var found: String?
      override func visitAny(_ node: Syntax) -> SyntaxVisitorContinueKind {
        guard found == nil else { return .skipChildren }
        if Self.holdsData(node) {
          found = node.trimmedDescription
          return .skipChildren
        }
        return .visitChildren
      }
      static func holdsData(_ node: Syntax) -> Bool {
        if let string = node.as(StringLiteralExprSyntax.self) {
          return !Judge.isEmptyString(string)
        }
        if let integer = node.as(IntegerLiteralExprSyntax.self) {
          return integer.literal.text != "0"
        }
        if let float = node.as(FloatLiteralExprSyntax.self) {
          return Double(float.literal.text.filter { $0 != "_" }) != 0
        }
        if let boolean = node.as(BooleanLiteralExprSyntax.self) {
          return boolean.literal.tokenKind == .keyword(.true)
        }
        if let array = node.as(ArrayExprSyntax.self) { return !array.elements.isEmpty }
        if let dictionary = node.as(DictionaryExprSyntax.self) {
          if case .colon = dictionary.content { return false }
          return true
        }
        return node.is(RegexLiteralExprSyntax.self)
      }
    }
    let finder = Finder(viewMode: .sourceAccurate)
    finder.walk(node)
    return finder.found
  }

  static func excerpt(_ item: CodeBlockItemSyntax) -> String {
    let collapsed = item.trimmedDescription.split(whereSeparator: \.isWhitespace).joined(
      separator: " ")
    return collapsed.count > 100 ? String(collapsed.prefix(100)) + "…" : collapsed
  }
}

import SwiftGateDomain
import SwiftParser
import SwiftSyntax

/// The functions and types a commit's parent declares, which a forwarding stub may call.
public struct SurfaceParentIndex: Sendable, Equatable {
  /// Function names, and property names too, since a forward may call a closure property (a TCA
  /// dependency client's endpoints are closures).
  public let functions: Set<String>
  public let types: Set<String>
  /// Enum case names, which an empty-payload case stub may construct.
  public let cases: Set<String>

  public init(functions: Set<String>, types: Set<String>, cases: Set<String> = []) {
    self.functions = functions
    self.types = types
    self.cases = cases
  }

  public static func build(_ sources: [String: String]) -> SurfaceParentIndex {
    let collector = DeclaredNames()
    for text in sources.values { collector.walk(Parser.parse(source: text)) }
    return SurfaceParentIndex(
      functions: collector.functions, types: collector.types, cases: collector.cases)
  }
}

private final class DeclaredNames: SyntaxVisitor {
  var functions: Set<String> = []
  var types: Set<String> = []
  var cases: Set<String> = []

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
  override func visit(_ node: EnumCaseDeclSyntax) -> SyntaxVisitorContinueKind {
    for element in node.elements { cases.insert(element.name.text) }
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
    scan(change) { name, kind in
      switch kind {
      case .function: parent.functions.contains(name)
      case .type: parent.types.contains(name)
      case .enumCase: parent.cases.contains(name)
      }
    }
  }

  private final class CalleeLog {
    var names: Set<String> = []
  }

  private static func scan(
    _ change: SurfaceFileChange, declares: @escaping (String, DeclaredKind) -> Bool
  ) -> [SurfaceJudgement] {
    guard let text = change.commitText else { return [] }
    if ManifestDiff.isManifest(change.path), let parentText = change.parentText {
      return ManifestDiff.judge(path: change.path, parentText: parentText, commitText: text)
    }
    let tree = Parser.parse(source: text)
    let fileNames = DeclaredNames()
    fileNames.walk(tree)
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
      let judge = Judge(
        enclosingType: unit.enclosingType, parameters: unit.parameters,
        fileCases: fileNames.cases, declares: declares)
      switch unit.kind {
      case .storedValue:
        // An added stored property is surface (§3.1); only a changed existing value is judged.
        if !candidates.isEmpty {
          let registers = candidates.contains { addsRegistrations(unit.node, over: $0.node) }
          add(
            registers ? .stub(.registersType) : .behaviour(.changesStoredValue),
            unit.declaration, unit.line)
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
        } else if candidates.contains(where: { addsRegistrations(unit.node, over: $0.node) }) {
          add(.stub(.registersType), unit.declaration, unit.line)
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
        other.id != clause.id && encloses(other, clause)
      }
    }
    guard !outermost.isEmpty else { return nil }
    let remaining = unit.node.tokens(viewMode: .sourceAccurate).filter { token in
      !outermost.contains { $0.position <= token.position && token.endPosition <= $0.endPosition }
    }
    guard remaining.map(\.text).joined(separator: " ") == previous.normalized else { return nil }
    return outermost
  }

  /// Whether clause `o` holds clause `i`. Distinct clauses never share a start or an end: a nested
  /// one starts after its enclosing clause's label and ends before its switch's closing brace.
  private static func encloses(_ o: SwitchCaseSyntax, _ i: SwitchCaseSyntax) -> Bool {
    let starts = o.position <= i.position  // swiftgate:equivalent-mutant — starts are never equal
    let ends = i.endPosition <= o.endPosition  // swiftgate:equivalent-mutant — ends are never equal
    return starts && ends
  }

  /// Whether `node`'s only change over `previous` is new array elements that are each a bare type
  /// reference or `Type.self`, as registering a command in an existing list is. Separating commas
  /// are ignored, since appending to a list without a trailing comma adds one to the old last
  /// element.
  private static func addsRegistrations(_ node: Syntax, over previous: Syntax) -> Bool {
    var known: [String: Int] = [:]
    for element in previous.arrayElements {
      known[normalize(Syntax(element.expression)), default: 0] += 1
    }
    var added: [ArrayElementSyntax] = []
    for element in node.arrayElements {
      let text = normalize(Syntax(element.expression))
      if let count = known[text], count > 0 {
        known[text] = count - 1
      } else {
        added.append(element)
      }
    }
    guard !added.isEmpty, added.allSatisfy({ isTypeReference($0.expression) }) else {
      return false
    }
    func withoutCommas(_ tokens: some Sequence<TokenSyntax>) -> String {
      tokens.filter { $0.tokenKind != .comma }.map(\.text).joined(separator: " ")
    }
    let remaining = node.tokens(viewMode: .sourceAccurate).filter { token in
      !added.contains { $0.position <= token.position && token.endPosition <= $0.endPosition }
    }
    return withoutCommas(remaining) == withoutCommas(previous.tokens(viewMode: .sourceAccurate))
  }

  /// `Name`, `Outer.Name` or either followed by `.self`, where each name is capitalized.
  private static func isTypeReference(_ expression: ExprSyntax) -> Bool {
    if let reference = expression.as(DeclReferenceExprSyntax.self) {
      return reference.argumentNames == nil && reference.baseName.text.first?.isUppercase == true
    }
    guard let member = expression.as(MemberAccessExprSyntax.self), let base = member.base,
      member.declName.argumentNames == nil
    else { return false }
    let name = member.declName.baseName.text
    return (name == "self" || name.first?.isUppercase == true) && isTypeReference(base)
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

/// An existing `Package.swift` read against its parent token by token, where only the lists
/// labelled `dependencies`, `products` and `targets` may gain elements (fast modes §3.2). Trivia
/// and commas are ignored; the tools-version comment is not.
enum ManifestDiff {
  struct Change {
    let excerpt: String
    let node: Syntax
  }

  static let listLabels: Set<String> = ["dependencies", "products", "targets"]
  /// The `PackageDescription` factories a manifest declares a package, product, target or target
  /// dependency with.
  static let declarations: Set<String> = [
    "package", "product", "target", "testTarget", "executableTarget", "macro", "plugin",
    "binaryTarget", "systemLibrary", "library", "executable", "byName",
  ]

  static func isManifest(_ path: String) -> Bool {
    path.split(separator: "/").last == "Package.swift"
  }

  static func judge(path: String, parentText: String, commitText: String) -> [SurfaceJudgement] {
    let tree = Parser.parse(source: commitText)
    let converter = SourceLocationConverter(fileName: path, tree: tree)
    func judgement(_ outcome: SurfaceJudgement.Outcome, _ node: Syntax?) -> [SurfaceJudgement] {
      let line = node.map { converter.location(for: $0.positionAfterSkippingLeadingTrivia).line }
      return [
        SurfaceJudgement(file: path, line: line ?? 1, declaration: "package", outcome: outcome)
      ]
    }
    let oldVersion = toolsVersion(parentText)
    let newVersion = toolsVersion(commitText)
    if oldVersion != newVersion {
      return judgement(
        .behaviour(.changesManifest(excerpt: newVersion ?? oldVersion ?? "")), nil)
    }
    var added: [Syntax] = []
    let parentTree = Syntax(Parser.parse(source: parentText))
    if let change = compare(parentTree, Syntax(tree), context: Syntax(tree), added: &added) {
      return judgement(.behaviour(.changesManifest(excerpt: change.excerpt)), change.node)
    }
    guard let first = added.min(by: { $0.position < $1.position }) else { return [] }
    return judgement(.stub(.extendsManifest), first)
  }

  /// The first line, when it is the `swift-tools-version` comment SwiftPM reads.
  private static func toolsVersion(_ text: String) -> String? {
    let line = text.prefix { $0 != "\n" }.trimmingTrailingWhitespace
    return line.hasPrefix("//") && line.lowercased().contains("swift-tools-version")
      ? line : nil
  }

  /// `nil` when `new` is `old` with only allowed list elements added, which land in `added`.
  /// `context` is the innermost argument, list element or statement holding `new`, which a
  /// change is reported by.
  static func compare(_ old: Syntax, _ new: Syntax, context: Syntax, added: inout [Syntax])
    -> Change?
  {
    if let oldToken = old.as(TokenSyntax.self), let newToken = new.as(TokenSyntax.self) {
      return oldToken.text == newToken.text ? nil : Change(excerpt: excerpt(context), node: context)
    }
    guard old.kind == new.kind else { return Change(excerpt: excerpt(context), node: context) }
    if let oldList = old.as(ArrayElementListSyntax.self),
      let newList = new.as(ArrayElementListSyntax.self)
    {
      return compareLists(Array(oldList), Array(newList), in: newList, added: &added)
    }
    // A removed last argument takes the comma before it along; skipping commas names the
    // argument instead of that comma.
    let oldChildren = old.children(viewMode: .sourceAccurate).filter { !isComma($0) }
    let newChildren = new.children(viewMode: .sourceAccurate).filter { !isComma($0) }
    for (oldChild, newChild) in zip(oldChildren, newChildren) {
      let inner = isContext(newChild) ? newChild : context
      if let change = compare(oldChild, newChild, context: inner, added: &added) { return change }
    }
    if newChildren.count > oldChildren.count {
      let extra = newChildren[oldChildren.count]
      return Change(excerpt: excerpt(extra), node: extra)
    }
    if oldChildren.count > newChildren.count {
      return Change(excerpt: excerpt(oldChildren[newChildren.count]), node: context)
    }
    return nil
  }

  /// Aligns the lists by the longest run of pairs that compare equal once additions are allowed,
  /// so a removed or changed element is told apart from the ones around it.
  private static func compareLists(
    _ old: [ArrayElementSyntax], _ new: [ArrayElementSyntax], in list: ArrayElementListSyntax,
    added: inout [Syntax]
  ) -> Change? {
    var memo: [Int: Bool] = [:]
    func matches(_ i: Int, _ j: Int) -> Bool {
      let key = i * new.count + j
      if let known = memo[key] { return known }
      var scratch: [Syntax] = []
      let result =
        compare(
          Syntax(old[i].expression), Syntax(new[j].expression),
          context: Syntax(new[j].expression), added: &scratch) == nil
      memo[key] = result
      return result
    }
    var longest = Array(repeating: Array(repeating: 0, count: new.count + 1), count: old.count + 1)
    for i in old.indices.reversed() {
      for j in new.indices.reversed() {
        let paired = matches(i, j) ? longest[i + 1][j + 1] + 1 : 0
        longest[i][j] = max(paired, longest[i + 1][j], longest[i][j + 1])
      }
    }
    var pairs: [(old: Int, new: Int)] = []
    var unmatchedOld: [Int] = []
    var unmatchedNew: [Int] = []
    var i = 0
    var j = 0
    while i < old.count || j < new.count {
      if i == old.count {
        unmatchedNew.append(j)
        j += 1
      } else if j == new.count {
        unmatchedOld.append(i)
        i += 1
      } else if matches(i, j), longest[i][j] == longest[i + 1][j + 1] + 1 {
        pairs.append((i, j))
        i += 1
        j += 1
      } else if longest[i + 1][j] >= longest[i][j + 1] {
        unmatchedOld.append(i)
        i += 1
      } else {
        unmatchedNew.append(j)
        j += 1
      }
    }
    for pair in pairs {
      _ = compare(
        Syntax(old[pair.old].expression), Syntax(new[pair.new].expression),
        context: Syntax(new[pair.new].expression), added: &added)
    }
    // An unmatched old element and an unmatched new one built the same way in the same gap
    // between aligned pairs are 1 element changed: comparing the two names the changed argument.
    func changed(old oldIndex: Int, new newIndex: Int) -> Change? {
      guard head(old[oldIndex].expression) == head(new[newIndex].expression) else { return nil }
      var scratch: [Syntax] = []
      return compare(
        Syntax(old[oldIndex].expression), Syntax(new[newIndex].expression),
        context: Syntax(new[newIndex].expression), added: &scratch)
    }
    func sameGap(old oldIndex: Int, new newIndex: Int) -> Bool {
      pairs.allSatisfy { ($0.old < oldIndex) == ($0.new < newIndex) }
    }
    let labelled = list.parent?.parent?.as(LabeledExprSyntax.self)?.label?.text
    let isDeclarationList = labelled.map(listLabels.contains) ?? false
    for index in unmatchedNew {
      let expression = new[index].expression
      guard isDeclarationList, isDeclaration(expression) else {
        for oldIndex in unmatchedOld where sameGap(old: oldIndex, new: index) {
          if let change = changed(old: oldIndex, new: index) { return change }
        }
        return Change(excerpt: excerpt(Syntax(expression)), node: Syntax(expression))
      }
      added.append(Syntax(new[index]))
    }
    guard let removed = unmatchedOld.first else { return nil }
    for index in unmatchedNew where sameGap(old: removed, new: index) {
      if let change = changed(old: removed, new: index) { return change }
    }
    return Change(
      excerpt: excerpt(Syntax(old[removed].expression)), node: list.parent ?? Syntax(list))
  }

  /// A target name string without interpolation, or a `.package`, `.product`, `.target` or
  /// other declaration factory call.
  private static func isDeclaration(_ expression: ExprSyntax) -> Bool {
    if let string = expression.as(StringLiteralExprSyntax.self) {
      return string.segments.allSatisfy {
        if case .stringSegment = $0 { return true }
        return false
      }
    }
    guard let call = expression.as(FunctionCallExprSyntax.self),
      let member = call.calledExpression.as(MemberAccessExprSyntax.self), member.base == nil
    else { return false }
    return declarations.contains(member.declName.baseName.text)
  }

  private static func head(_ expression: ExprSyntax) -> String? {
    expression.as(FunctionCallExprSyntax.self)?.calledExpression.trimmedDescription
  }

  private static func isComma(_ node: Syntax) -> Bool {
    node.as(TokenSyntax.self)?.tokenKind == .comma
  }

  /// A labelled argument (`exact: "1.2.0"`) or a statement; an unlabelled argument such as
  /// `.v18` says too little on its own, so its call is reported instead.
  private static func isContext(_ node: Syntax) -> Bool {
    node.as(LabeledExprSyntax.self)?.label != nil || node.is(CodeBlockItemSyntax.self)
  }

  private static func excerpt(_ node: Syntax) -> String {
    var collapsed = node.trimmedDescription.split(whereSeparator: \.isWhitespace).joined(
      separator: " ")
    if collapsed.hasSuffix(",") { collapsed.removeLast() }
    return collapsed.count > 100 ? String(collapsed.prefix(100)) + "…" : collapsed
  }
}

extension Substring {
  fileprivate var trimmingTrailingWhitespace: String {
    String(self[..<(lastIndex { !$0.isWhitespace }.map(index(after:)) ?? startIndex)])
  }
}

/// What a stub asks the parent whether it declares.
private enum DeclaredKind {
  case function
  case type
  case enumCase
}

/// Where a body sits, which picks the stub rules it's held to.
private enum BodyContext {
  case function
  /// An `init`, which may also assign its parameters to stored properties.
  case initializer
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
  /// The enclosing function's, initializer's, subscript's or closure's parameter names.
  let parameters: Set<String>
  let isTest: Bool
}

extension Syntax {
  fileprivate var arrayElements: [ArrayElementSyntax] {
    final class Finder: SyntaxVisitor {
      var found: [ArrayElementSyntax] = []
      override func visit(_ node: ArrayElementSyntax) -> SyntaxVisitorContinueKind {
        found.append(node)
        return .visitChildren
      }
    }
    let finder = Finder(viewMode: .sourceAccurate)
    finder.walk(self)
    return finder.found
  }

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
        parameters: names(node.signature.parameterClause.parameters),
        isTest: isTest || node.name.text.hasPrefix("test"))
    }
    return .skipChildren
  }

  override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
    if let body = node.body {
      add(
        key: "init", name: "init(\(labels(node.signature.parameterClause.parameters)))",
        at: Syntax(node), context: .initializer, kind: .body(body.statements), node: Syntax(body),
        parameters: names(node.signature.parameterClause.parameters))
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
        at: Syntax(node), context: .function,
        parameters: names(node.parameterClause.parameters))
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
          context: .function, kind: .body(closure.statements), node: Syntax(closure),
          parameters: Self.names(closure.signature))
      }
      let masked = value.tokens(viewMode: .sourceAccurate).filter { token in
        !closures.contains { $0.position <= token.position && token.endPosition <= $0.endPosition }
      }
      units.append(
        BodyUnit(
          key: containerKey("var \(name).value"), declaration: qualified(name),
          line: line(of: Syntax(node)), context: .function, kind: .storedValue, node: Syntax(value),
          normalized: masked.map(\.text).joined(separator: " "), enclosingType: containers.last,
          parameters: [], isTest: false))
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
    context: BodyContext, parameters: Set<String> = []
  ) {
    switch block.accessors {
    case .getter(let items):
      add(
        key: key, name: name, at: node, context: context, kind: .body(items), node: Syntax(items),
        parameters: parameters)
    case .accessors(let list):
      for accessor in list {
        guard let body = accessor.body else { continue }
        let specifier = accessor.accessorSpecifier.text
        add(
          key: "\(key).\(specifier)", name: "\(name).\(specifier)", at: Syntax(accessor),
          context: specifier == "get" ? context : .function, kind: .body(body.statements),
          node: Syntax(body), parameters: parameters)
      }
    }
  }

  private func add(
    key: String, name: String, at declaration: Syntax, context: BodyContext, kind: BodyUnit.Kind,
    node: Syntax, parameters: Set<String> = [], isTest: Bool = false, qualify: Bool = true
  ) {
    units.append(
      BodyUnit(
        key: qualify ? containerKey(key) : "\(key)#\(previewIndex())",
        declaration: qualify ? qualified(name) : name, line: line(of: declaration),
        context: context, kind: kind, node: node, normalized: SurfaceBodyScan.normalize(node),
        enclosingType: containers.last, parameters: parameters, isTest: isTest))
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

  /// The names a body refers to its parameters by: the second name when there is one.
  private func names(_ parameters: FunctionParameterListSyntax) -> Set<String> {
    Set(parameters.map { ($0.secondName ?? $0.firstName).text }.filter { $0 != "_" })
  }

  static func names(_ signature: ClosureSignatureSyntax?) -> Set<String> {
    switch signature?.parameterClause {
    case .simpleInput(let parameters): Set(parameters.map(\.name.text).filter { $0 != "_" })
    case .parameterClause(let clause):
      Set(clause.parameters.map { ($0.secondName ?? $0.firstName).text }.filter { $0 != "_" })
    case nil: []
    }
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
  let parameters: Set<String>
  /// Enum cases the changed file itself declares, so a new enum's case needs no parent lookup.
  let fileCases: Set<String>
  let declares: (String, DeclaredKind) -> Bool

  static let traps: Set<String> = ["fatalError", "preconditionFailure"]

  func body(_ items: CodeBlockItemListSyntax, context: BodyContext) -> SurfaceJudgement.Outcome {
    if let trap = Self.firstTrap(in: Syntax(items)) { return .behaviour(.traps(callee: trap)) }
    switch context {
    case .function: return stub(items)
    case .initializer: return initializer(items)
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

  /// An `init` is a plain stub, or only assignments `self.x = <parameter or empty default>`. Any
  /// other right-hand side names the first assignment that holds it.
  private func initializer(_ items: CodeBlockItemListSyntax) -> SurfaceJudgement.Outcome {
    let stubbed = stub(items)
    if case .stub = stubbed { return stubbed }
    let assignments = items.map { item in (item, Self.selfAssignment(item)) }
    guard assignments.allSatisfy({ $0.1 != nil }) else { return stubbed }
    for (item, assigned) in assignments {
      guard let assigned, assigned.count == 1, let value = assigned.first else {
        return .behaviour(.notAStub(excerpt: Self.excerpt(item)))
      }
      if Self.isEmptyDefault(value) || isParameter(value) { continue }
      return .behaviour(.notAStub(excerpt: Self.excerpt(item)))
    }
    return .stub(.assignsParameters)
  }

  /// The right-hand side of `self.x = …` as its unfolded sequence elements, or `nil` for any other
  /// statement.
  private static func selfAssignment(_ item: CodeBlockItemSyntax) -> [ExprSyntax]? {
    guard let sequence = value(of: item)?.as(SequenceExprSyntax.self) else { return nil }
    let elements = Array(sequence.elements)
    guard elements.count >= 3, elements[1].is(AssignmentExprSyntax.self),
      let target = elements[0].as(MemberAccessExprSyntax.self),
      target.base?.as(DeclReferenceExprSyntax.self)?.baseName.tokenKind == .keyword(.self)
    else { return nil }
    return Array(elements.dropFirst(2))
  }

  private func isParameter(_ expression: ExprSyntax) -> Bool {
    guard let reference = expression.as(DeclReferenceExprSyntax.self) else { return false }
    return reference.argumentNames == nil && parameters.contains(reference.baseName.text)
  }

  /// A value built by 1 initializer call (`Type(…)`, `.init(…)`, `Type.init(…)`) whose arguments
  /// are each an empty default or a parameter passed through unchanged.
  private func isEmptyValue(_ call: FunctionCallExprSyntax) -> Bool {
    guard call.trailingClosure == nil, call.additionalTrailingClosures.isEmpty,
      call.arguments.allSatisfy({ Self.isEmptyDefault($0.expression) || isParameter($0.expression) }
      )
    else { return false }
    if let reference = call.calledExpression.as(DeclReferenceExprSyntax.self) {
      return reference.baseName.text.first?.isUppercase == true
    }
    guard let member = call.calledExpression.as(MemberAccessExprSyntax.self),
      member.declName.baseName.text == "init"
    else { return false }
    return Self.isTypeOrOmitted(member.base)
  }

  private func stub(_ items: CodeBlockItemListSyntax) -> SurfaceJudgement.Outcome {
    guard let first = items.first else { return .stub(.empty) }
    guard items.count == 1 else { return .behaviour(.notAStub(excerpt: Self.excerpt(first))) }
    if let returned = first.item.as(ReturnStmtSyntax.self), returned.expression == nil {
      return .stub(.empty)
    }
    if let thrown = first.item.as(ThrowStmtSyntax.self) {
      return isErrorValue(thrown.expression)
        ? .stub(.throwsError) : .behaviour(.notAStub(excerpt: Self.excerpt(first)))
    }
    if let value = Self.value(of: first), let outcome = judgeValue(value) { return outcome }
    return .behaviour(.notAStub(excerpt: Self.excerpt(first)))
  }

  private func judgeValue(_ expression: ExprSyntax) -> SurfaceJudgement.Outcome? {
    let value = Self.unwrapped(expression)
    if Self.isEmptyDefault(value) { return .stub(.emptyDefault) }
    if Self.isPayloadFreeCase(value) { return .stub(.payloadFreeCase) }
    if isUnchanged(value) { return .stub(.returnsUnchanged) }
    if let call = value.as(FunctionCallExprSyntax.self) {
      let forwarded = forward(call)
      if forwarded == .stub(.forward) { return forwarded }
      if isEmptyValue(call) { return .stub(.emptyValue) }
      if isEmptyPayloadCase(call) { return .stub(.emptyPayloadCase) }
      return forwarded
    }
    return nil
  }

  /// A parameter, a bare property name, or 1 `self.` access, with no call, operator or longer
  /// member chain. A bare name can't be told from a computed property by syntax alone.
  private func isUnchanged(_ value: ExprSyntax) -> Bool {
    if let reference = value.as(DeclReferenceExprSyntax.self) {
      guard reference.argumentNames == nil, case .identifier = reference.baseName.tokenKind
      else { return false }
      return reference.baseName.text.first?.isUppercase != true
    }
    guard let member = value.as(MemberAccessExprSyntax.self), member.declName.argumentNames == nil,
      case .identifier = member.declName.baseName.tokenKind,
      member.declName.baseName.text.first?.isUppercase != true,
      member.base?.as(DeclReferenceExprSyntax.self)?.baseName.tokenKind == .keyword(.self)
    else { return false }
    return true
  }

  /// `.name(…)` or `Type.name(…)` where `name` is a case the parent or this file declares and each
  /// associated value is an empty default or a parameter passed through; a static function called
  /// the same way isn't a case.
  private func isEmptyPayloadCase(_ call: FunctionCallExprSyntax) -> Bool {
    guard call.trailingClosure == nil, call.additionalTrailingClosures.isEmpty,
      !call.arguments.isEmpty,
      call.arguments.allSatisfy({ Self.isEmptyDefault($0.expression) || isParameter($0.expression) }
      ),
      let member = call.calledExpression.as(MemberAccessExprSyntax.self),
      member.declName.argumentNames == nil, Self.isTypeOrOmitted(member.base)
    else { return false }
    let name = member.declName.baseName.text
    return fileCases.contains(name) || declares(name, .enumCase)
  }

  /// The value of a throw-only stub: a payload-free case with or without its type, an initializer
  /// call from empty defaults and parameters, or an empty-payload case.
  private func isErrorValue(_ value: ExprSyntax) -> Bool {
    if Self.isPayloadFreeCase(value) { return true }
    if let member = value.as(MemberAccessExprSyntax.self), member.base != nil,
      member.declName.argumentNames == nil,
      member.declName.baseName.text.first?.isLowercase == true, Self.isTypeOrOmitted(member.base)
    {
      return true
    }
    guard let call = value.as(FunctionCallExprSyntax.self) else { return false }
    return isEmptyValue(call) || isEmptyPayloadCase(call)
  }

  /// No base (`.name`), or a capitalized type name, possibly qualified (`Outer.Inner`).
  private static func isTypeOrOmitted(_ base: ExprSyntax?) -> Bool {
    guard let base else { return true }
    if let reference = base.as(DeclReferenceExprSyntax.self) {
      return reference.argumentNames == nil && reference.baseName.text.first?.isUppercase == true
    }
    guard let member = base.as(MemberAccessExprSyntax.self), member.base != nil,
      member.declName.argumentNames == nil,
      member.declName.baseName.text.first?.isUppercase == true
    else { return false }
    return isTypeOrOmitted(member.base)
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
    return declares(name, isType ? .type : .function)
      ? .stub(.forward) : .behaviour(.forwardsToNewCode(callee: name))
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

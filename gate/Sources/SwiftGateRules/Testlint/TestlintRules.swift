import SwiftGateDomain
import SwiftSyntax

/// Useless-test detection (spec §7.4, static layer) plus the two pyramid-placement rules that need
/// injected config and module scopes.
public enum TestlintRules {
  public static let all: [any Rule] = [
    NoAssertionRule(), TautologyRule(), ExistenceOnlyRule(), AssertsOwnDoubleRule(),
    SwallowedErrorRule(), SleepRule(), DuplicateTestRule(), UnnamedTestRule(),
    NonExhaustiveStoreRule(), XCUITestFlowRule(), MisplacedT2Rule(),
  ]
}

/// Per-file facts testlint rules share.
struct TestFile {
  let unit: SourceUnit
  let tests: [TestFunction]
  /// Names of file-local non-test functions that (transitively) contain assertions.
  let assertingHelpers: Set<String>

  init(_ unit: SourceUnit) {
    self.unit = unit
    tests = TestFunction.all(in: unit)
    let testIDs = Set(tests.map(\.decl.id))
    let helpers = unit.tree.descendants(of: FunctionDeclSyntax.self).filter {
      !testIDs.contains($0.id) && $0.body != nil
    }
    var asserting = Set<String>()
    var changed = true
    while changed {
      changed = false
      for helper in helpers where !asserting.contains(helper.name.text) {
        guard let body = helper.body else { continue }
        if !AssertionSyntax.assertions(in: body).isEmpty
          || AssertionSyntax.callsHelper(in: body, named: asserting)
        {
          asserting.insert(helper.name.text)
          changed = true
        }
      }
    }
    assertingHelpers = asserting
  }

  func hasAssertion(_ test: TestFunction) -> Bool {
    guard let body = test.body else { return true }
    return !AssertionSyntax.assertions(in: body).isEmpty
      || AssertionSyntax.callsHelper(in: body, named: assertingHelpers)
  }
}

private let redSeverity = Severity.major

// MARK: - Assertion quality

struct NoAssertionRule: FileRule {
  let descriptor = RuleDescriptor(
    id: "test.no-assertion", severity: redSeverity, summary: "test has no assertion")
  let scope = RuleScope.testFiles

  func check(_ unit: SourceUnit, context: RuleContext) -> [RuleViolation] {
    let file = TestFile(unit)
    return file.tests.filter { test in
      guard let body = test.body else { return false }
      let isPerformanceTest = body.descendants(of: FunctionCallExprSyntax.self).contains {
        $0.callee?.name == "measure"
      }
      return !isPerformanceTest && !file.hasAssertion(test)
    }.map {
      unit.violation(
        atStartOf: $0.decl.funcKeyword,
        message: "test `\($0.name)` has no assertion, so it cannot fail on wrong behavior",
        failureScenario: "the behavior it names breaks and the test still passes")
    }
  }
}

/// The variables a test builds itself and never hands to the code under test, with the literal
/// values it configured on them (initializer labels and member assignments).
struct SelfConfiguredValues {
  struct Entry {
    let typeName: String
    /// member → configured literal source text.
    var members: [String: String]
  }

  var byVariable: [String: Entry] = [:]

  init(body: CodeBlockSyntax) {
    var candidates: [String: Entry] = [:]
    for decl in body.descendants(of: VariableDeclSyntax.self) {
      for binding in decl.bindings {
        guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
          let call = binding.initializer?.value.as(FunctionCallExprSyntax.self),
          let typeName = Self.constructedTypeName(call)
        else { continue }
        var members: [String: String] = [:]
        for argument in call.arguments {
          if let label = argument.label?.text, Self.isLiteral(argument.expression) {
            members[label] = argument.expression.trimmedDescription
          }
        }
        candidates[name] = Entry(typeName: typeName, members: members)
      }
    }
    for sequence in body.descendants(of: SequenceExprSyntax.self) {
      let elements = Array(sequence.elements)
      guard elements.count == 3, elements[1].is(AssignmentExprSyntax.self),
        let member = elements[0].as(MemberAccessExprSyntax.self),
        let base = member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text,
        candidates[base] != nil, Self.isLiteral(elements[2])
      else { continue }
      candidates[base]?.members[member.declName.baseName.text] = elements[2].trimmedDescription
    }
    for (name, _) in candidates where Self.isUsedBeyondConfiguration(name, in: body) {
      candidates[name] = nil
    }
    byVariable = candidates
  }

  /// `Foo(...)`, `Module.Foo(...)` or `Foo.init(...)`: a constructor, not a call into the SUT.
  static func constructedTypeName(_ call: FunctionCallExprSyntax) -> String? {
    guard let callee = call.callee else { return nil }
    if callee.name == "init", let base = callee.base { return base }
    guard callee.name.first?.isUppercase == true else { return nil }
    return callee.name
  }

  static func isLiteral(_ expression: ExprSyntax) -> Bool {
    if let prefix = expression.as(PrefixOperatorExprSyntax.self) {
      return isLiteral(prefix.expression)
    }
    return expression.is(IntegerLiteralExprSyntax.self)
      || expression.is(FloatLiteralExprSyntax.self)
      || expression.is(StringLiteralExprSyntax.self) || expression.is(BooleanLiteralExprSyntax.self)
      || expression.is(NilLiteralExprSyntax.self)
  }

  /// Every reference must be the declaration, the base of a configuring assignment, or the base
  /// of a member read that is a whole side of a comparison inside an assertion.
  private static func isUsedBeyondConfiguration(_ name: String, in body: CodeBlockSyntax) -> Bool {
    for reference in body.descendants(of: DeclReferenceExprSyntax.self)
    where reference.baseName.text == name {
      guard let member = reference.parent?.as(MemberAccessExprSyntax.self),
        member.base?.id == reference.id
      else { return true }
      if let sequence = member.parent?.parent?.as(SequenceExprSyntax.self) {
        let elements = Array(sequence.elements)
        if elements.count == 3, elements[0].id == member.id,
          elements[1].is(AssignmentExprSyntax.self)
        {
          continue
        }
        if elements.count == 3, elements[1].is(BinaryOperatorExprSyntax.self),
          insideAssertion(sequence)
        {
          continue
        }
        return true
      }
      if member.parent?.is(LabeledExprSyntax.self) == true, insideAssertion(member) {
        continue
      }
      return true
    }
    return false
  }

  static func insideAssertion(_ node: some SyntaxProtocol) -> Bool {
    var current = node.parent
    while let node = current {
      if AssertionSyntax.isAssertion(node) { return true }
      if node.is(CodeBlockItemSyntax.self) { return false }
      current = node.parent
    }
    return false
  }

  /// Whether `side` reads a configured member (`v.m`) and `other` is the literal it was set to.
  func configuredMatch(_ side: String, _ other: String) -> Entry? {
    let parts = side.split(separator: ".", maxSplits: 1).map(String.init)
    guard parts.count == 2, let entry = byVariable[parts[0]], entry.members[parts[1]] == other
    else { return nil }
    return entry
  }

  func isDouble(_ entry: Entry) -> Bool {
    ["Mock", "Stub", "Fake", "Spy", "Dummy"].contains {
      entry.typeName.hasPrefix($0) || entry.typeName.hasSuffix($0)
    }
  }
}

/// Assertions of a test that compare a self-configured value with the literal it was given.
private func selfConfiguredAssertions(
  in test: TestFunction, doubles: Bool
) -> [Syntax] {
  guard let body = test.body else { return [] }
  let values = SelfConfiguredValues(body: body)
  guard !values.byVariable.isEmpty else { return [] }
  return AssertionSyntax.assertions(in: body).filter { assertion in
    let sides = comparedSides(of: assertion)
    guard let (left, right) = sides else { return false }
    let entry = values.configuredMatch(left, right) ?? values.configuredMatch(right, left)
    guard let entry else { return false }
    return values.isDouble(entry) == doubles
  }
}

/// The two sides an assertion compares: `#expect(a == b)` or `XCTAssertEqual(a, b)`.
private func comparedSides(of assertion: Syntax) -> (String, String)? {
  guard let arguments = AssertionSyntax.arguments(of: assertion), let first = arguments.first
  else { return nil }
  let name = AssertionSyntax.name(of: assertion)
  if name == "XCTAssertEqual" || name == "XCTAssertIdentical", arguments.count >= 2 {
    let second = arguments[arguments.index(after: arguments.startIndex)]
    return (first.expression.trimmedDescription, second.expression.trimmedDescription)
  }
  if let comparison = AssertionSyntax.comparison(first.expression),
    ["==", "==="].contains(comparison.op)
  {
    return (comparison.left, comparison.right)
  }
  return nil
}

struct TautologyRule: FileRule {
  let descriptor = RuleDescriptor(
    id: "test.tautology", severity: redSeverity,
    summary: "assertion that cannot fail (literal, self-comparison, value the test just built)")
  let scope = RuleScope.testFiles

  func check(_ unit: SourceUnit, context: RuleContext) -> [RuleViolation] {
    var violations: [RuleViolation] = []
    for test in TestFile(unit).tests {
      guard let body = test.body else { continue }
      var flagged = Set<SyntaxIdentifier>()
      for assertion in AssertionSyntax.assertions(in: body) where isTautology(assertion) {
        flagged.insert(assertion.id)
        violations.append(
          unit.violation(
            atStartOf: assertion, message: "assertion cannot fail: it compares a value with itself")
        )
      }
      for assertion in selfConfiguredAssertions(in: test, doubles: false)
      where !flagged.contains(assertion.id) {
        violations.append(
          unit.violation(
            atStartOf: assertion,
            message:
              "assertion reads back a literal the test itself passed to the initializer; "
              + "exercise the code under test instead"))
      }
    }
    return violations
  }

  private func isTautology(_ assertion: Syntax) -> Bool {
    guard let arguments = AssertionSyntax.arguments(of: assertion), let first = arguments.first
    else { return false }
    let name = AssertionSyntax.name(of: assertion)
    let text = first.expression.trimmedDescription
    switch name {
    case "#expect", "#require", "XCTAssert", "XCTAssertTrue":
      if text == "true" { return true }
      if let comparison = AssertionSyntax.comparison(first.expression),
        ["==", "===", ">=", "<="].contains(comparison.op)
      {
        return comparison.left == comparison.right
      }
      return false
    case "XCTAssertFalse":
      return text == "false"
    case "XCTAssertEqual", "XCTAssertIdentical", "XCTAssertGreaterThanOrEqual",
      "XCTAssertLessThanOrEqual":
      guard arguments.count >= 2 else { return false }
      let second = arguments[arguments.index(after: arguments.startIndex)]
      return text == second.expression.trimmedDescription
    default:
      return false
    }
  }
}

struct ExistenceOnlyRule: FileRule {
  let descriptor = RuleDescriptor(
    id: "test.existence-only", severity: redSeverity,
    summary: "test's only assertions are non-nil checks")
  let scope = RuleScope.testFiles

  func check(_ unit: SourceUnit, context: RuleContext) -> [RuleViolation] {
    TestFile(unit).tests.compactMap { test in
      guard let body = test.body else { return nil }
      let assertions = AssertionSyntax.assertions(in: body)
      guard !assertions.isEmpty, assertions.allSatisfy(isExistenceCheck) else { return nil }
      return unit.violation(
        atStartOf: test.decl.funcKeyword,
        message:
          "test `\(test.name)` only checks that something is non-nil; assert the behavior it names",
        failureScenario: "the value exists but is wrong and the test still passes")
    }
  }

  private func isExistenceCheck(_ assertion: Syntax) -> Bool {
    guard let arguments = AssertionSyntax.arguments(of: assertion), let first = arguments.first
    else { return false }
    switch AssertionSyntax.name(of: assertion) {
    case "XCTAssertNotNil":
      return true
    case "#require", "XCTUnwrap":
      // Unwrapping whose result is kept is a presence check; `try #require(flag)` as a bare
      // statement asserts a Bool.
      return !isBareStatement(assertion)
    case "#expect", "XCTAssert", "XCTAssertTrue":
      guard let comparison = AssertionSyntax.comparison(first.expression) else { return false }
      return comparison.op == "!=" && (comparison.left == "nil" || comparison.right == "nil")
    default:
      return false
    }
  }

  private func isBareStatement(_ node: Syntax) -> Bool {
    var current = node.parent
    while let parent = current {
      if parent.is(CodeBlockItemSyntax.self) { return true }
      if parent.is(TryExprSyntax.self) || parent.is(AwaitExprSyntax.self)
        || parent.is(ExpressionStmtSyntax.self)
      {
        current = parent.parent
        continue
      }
      return false
    }
    return false
  }
}

struct AssertsOwnDoubleRule: FileRule {
  let descriptor = RuleDescriptor(
    id: "test.asserts-own-double", severity: redSeverity,
    summary: "assertion checks a value the test configured on its own double")
  let scope = RuleScope.testFiles

  func check(_ unit: SourceUnit, context: RuleContext) -> [RuleViolation] {
    TestFile(unit).tests.flatMap { test in
      selfConfiguredAssertions(in: test, doubles: true).map {
        unit.violation(
          atStartOf: $0,
          message:
            "assertion reads back a value the test configured on its own double; pass the "
            + "double to the code under test and assert the code's output")
      }
    }
  }
}

struct SwallowedErrorRule: FileRule {
  let descriptor = RuleDescriptor(
    id: "test.swallowed-error", severity: redSeverity,
    summary: "`try?` or a catch without an issue in a test body")
  let scope = RuleScope.testFiles

  func check(_ unit: SourceUnit, context: RuleContext) -> [RuleViolation] {
    var violations: [RuleViolation] = []
    for test in TestFile(unit).tests {
      guard let body = test.body else { continue }
      for expression in body.descendants(of: TryExprSyntax.self)
      where expression.questionOrExclamationMark?.tokenKind == .postfixQuestionMark
        && !SelfConfiguredValues.insideAssertion(expression) && !Self.isTeardown(expression)
      {
        violations.append(
          unit.violation(
            atStartOf: expression,
            message: "`try?` in a test discards the error; mark the test `throws` and use `try`"))
      }
      for clause in body.descendants(of: CatchClauseSyntax.self)
      where AssertionSyntax.assertions(in: clause.body).isEmpty
        && clause.body.descendants(of: ThrowStmtSyntax.self).isEmpty
      {
        violations.append(
          unit.violation(
            atStartOf: clause.catchKeyword,
            message: "catch swallows the error; record it with `Issue.record(error)` or rethrow"))
      }
    }
    return violations
  }

  /// Best-effort cleanup in `defer` cannot hide a failure of the behavior under test.
  private static func isTeardown(_ node: some SyntaxProtocol) -> Bool {
    var current = node.parent
    while let parent = current {
      if parent.is(DeferStmtSyntax.self) { return true }
      if parent.is(FunctionDeclSyntax.self) || parent.is(ClosureExprSyntax.self) { return false }
      current = parent.parent
    }
    return false
  }
}

struct SleepRule: FileRule {
  let descriptor = RuleDescriptor(
    id: "test.sleep", severity: redSeverity, summary: "real sleep in a test")
  let scope = RuleScope.testFiles

  func check(_ unit: SourceUnit, context: RuleContext) -> [RuleViolation] {
    unit.tree.descendants(of: FunctionCallExprSyntax.self).compactMap { call in
      guard let callee = call.callee else { return nil }
      let isSleep =
        switch (callee.base, callee.name) {
        case ("Task", "sleep"), ("Thread", "sleep"), (nil, "sleep"), (nil, "usleep"),
          (nil, "nanosleep"):
          true
        default: false
        }
      guard isSleep else { return nil }
      return unit.violation(
        atStartOf: call,
        message:
          "real sleep in a test makes it slow and flaky; inject a clock (TestClock/ImmediateClock)")
    }
  }
}

struct DuplicateTestRule: Rule {
  let descriptor = RuleDescriptor(
    id: "test.duplicate", severity: redSeverity, summary: "test body duplicates another test")
  let scope = RuleScope.testFiles

  func check(_ units: [SourceUnit], context: RuleContext) -> [RuleViolation] {
    var firstByBody: [String: (path: String, line: Int, name: String)] = [:]
    var violations: [RuleViolation] = []
    let ordered = units.sorted { $0.path < $1.path }
    for unit in ordered {
      for test in TestFile(unit).tests {
        guard let body = test.body, !body.statements.isEmpty else { continue }
        let key = body.statements.tokens(viewMode: .sourceAccurate).map(\.text)
          .joined(separator: " ")
        let line = unit.line(of: test.decl.funcKeyword.positionAfterSkippingLeadingTrivia)
        if let first = firstByBody[key] {
          violations.append(
            RuleViolation(
              path: unit.path, lines: line...line,
              message:
                "test `\(test.name)` has the same body as `\(first.name)` at "
                + "\(first.path):\(first.line); delete one or make them test different cases"))
        } else {
          firstByBody[key] = (unit.path, line, test.name)
        }
      }
    }
    return violations
  }
}

struct UnnamedTestRule: FileRule {
  let descriptor = RuleDescriptor(
    id: "test.unnamed", severity: redSeverity, summary: "@Test without a display name")
  let scope = RuleScope.testFiles

  func check(_ unit: SourceUnit, context: RuleContext) -> [RuleViolation] {
    TestFile(unit).tests.compactMap { test in
      guard let attribute = test.testAttribute else { return nil }
      if case .argumentList(let arguments) = attribute.arguments, let first = arguments.first,
        first.label == nil, first.expression.is(StringLiteralExprSyntax.self)
      {
        return nil
      }
      return unit.violation(
        atStartOf: attribute,
        message:
          "@Test without a display name; name the regression it catches: "
          + "@Test(\"<behavior> — catches <regression>\")")
    }
  }
}

struct NonExhaustiveStoreRule: FileRule {
  let descriptor = RuleDescriptor(
    id: "test.non-exhaustive-store", severity: redSeverity,
    summary: "non-exhaustive TestStore without a same-line justification")
  let scope = RuleScope.testFiles

  private let message =
    "non-exhaustive TestStore skips state assertions; keep it exhaustive or justify with "
    + "`// swiftgate:allow test.non-exhaustive-store — <reason>`"

  func check(_ unit: SourceUnit, context: RuleContext) -> [RuleViolation] {
    var violations: [RuleViolation] = []
    for sequence in unit.tree.descendants(of: SequenceExprSyntax.self) {
      let elements = Array(sequence.elements)
      guard elements.count == 3, elements[1].is(AssignmentExprSyntax.self),
        let member = elements[0].as(MemberAccessExprSyntax.self),
        member.declName.baseName.text == "exhaustivity", !isOn(elements[2])
      else { continue }
      violations.append(unit.violation(atStartOf: sequence, message: message))
    }
    for call in unit.tree.descendants(of: FunctionCallExprSyntax.self)
    where call.callee?.name == "withExhaustivity" {
      if let argument = call.arguments.first?.expression, isOn(argument) { continue }
      violations.append(unit.violation(atStartOf: call, message: message))
    }
    return violations
  }

  private func isOn(_ expression: ExprSyntax) -> Bool {
    expression.as(MemberAccessExprSyntax.self)?.declName.baseName.text == "on"
  }
}

// MARK: - Pyramid placement

/// Every XCUITest must belong to a declared `[[flows]]` entry: its method name (after `test`) or
/// its class name starts with the flow name, compared case- and punctuation-insensitively.
struct XCUITestFlowRule: FileRule {
  let descriptor = RuleDescriptor(
    id: "test.xcuitest-unlisted-flow", severity: redSeverity,
    summary: "XCUITest outside the declared [[flows]]")
  let scope = RuleScope.testFiles

  func check(_ unit: SourceUnit, context: RuleContext) -> [RuleViolation] {
    guard let flows = context.flows else { return [] }
    let isUITestFile =
      unit.scope?.role == .tests(.t3)
      || unit.tree.descendants(of: DeclReferenceExprSyntax.self).contains {
        $0.baseName.text == "XCUIApplication"
      }
    guard isUITestFile else { return [] }
    let flowKeys = flows.map(Self.normalized).filter { !$0.isEmpty }
    return TestFile(unit).tests.filter { $0.framework == .xcTest }.compactMap { test in
      let method = Self.normalized(String(test.name.dropFirst("test".count)))
      let type = Self.normalized(test.enclosingType ?? "")
      guard !flowKeys.contains(where: { method.hasPrefix($0) || type.hasPrefix($0) }) else {
        return nil
      }
      return unit.violation(
        atStartOf: test.decl.funcKeyword,
        message:
          "XCUITest `\(test.name)` maps to no [[flows]] entry (\(flows.joined(separator: ", "))); "
          + "cover it at T1/T2 or declare the flow with a reason")
    }
  }

  static func normalized(_ text: String) -> String {
    String(text.lowercased().filter { $0.isLetter || $0.isNumber })
  }
}

/// A simulator (T2) test that renders no view or snapshot and imports only Core/Client modules
/// belongs in T1. Needs module scopes: without tier data (`tests(.t2)`) it never fires.
struct MisplacedT2Rule: FileRule {
  let descriptor = RuleDescriptor(
    id: "test.misplaced-t2", severity: redSeverity,
    summary: "T2 test with no view/snapshot and only Core/Client imports")
  let scope = RuleScope.roles([.tests(.t2)])

  private static let renderingFrameworks: Set<String> = [
    "SwiftUI", "UIKit", "AppKit", "SnapshotTesting", "ViewInspector",
  ]

  func check(_ unit: SourceUnit, context: RuleContext) -> [RuleViolation] {
    if unit.imports.contains(where: Self.renderingFrameworks.contains) { return [] }
    let rendersSnapshot = unit.tree.descendants(of: FunctionCallExprSyntax.self).contains {
      $0.callee?.name.hasPrefix("assertSnapshot") == true
        || $0.callee?.name == "assertInlineSnapshot"
    }
    if rendersSnapshot { return [] }
    var firstPartyImport: ImportDeclSyntax?
    for item in unit.tree.statements {
      guard let decl = item.item.as(ImportDeclSyntax.self),
        let name = decl.path.first?.name.text,
        let scope = context.scopes.scope(ofModule: name)
      else { continue }
      guard scope.role == .core || scope.role == .client else { return [] }
      if firstPartyImport == nil { firstPartyImport = decl }
    }
    guard let firstPartyImport else { return [] }
    return [
      unit.violation(
        atStartOf: firstPartyImport.importKeyword,
        message:
          "simulator (T2) test renders no view or snapshot and imports only Core/Client modules; "
          + "move it to the module's T1 host tests")
    ]
  }
}

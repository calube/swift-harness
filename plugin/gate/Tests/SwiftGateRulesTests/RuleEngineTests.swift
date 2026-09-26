import SwiftGateDomain
import SwiftGateRules
import SwiftSyntax
import Testing

/// Flags every call to a free function named `forbidden`, the smallest rule that exercises the
/// engine's syntax-only matching.
private struct ForbiddenCallRule: FileRule {
  let descriptor = RuleDescriptor(
    id: "test.forbidden-call", severity: .major, summary: "calls forbidden()")
  var scope: RuleScope = .allFiles

  func check(_ unit: SourceUnit, context: RuleContext) -> [RuleViolation] {
    unit.tree.descendants(of: FunctionCallExprSyntax.self)
      .filter { $0.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == "forbidden" }
      .map { unit.violation(at: $0, message: "forbidden() called") }
  }
}

/// Reports one violation spanning the second to fourth lines of every file, to exercise
/// added-line filtering.
private struct SpanRule: FileRule {
  let descriptor = RuleDescriptor(id: "test.span", severity: .minor, summary: "span")
  let scope: RuleScope = .allFiles

  func check(_ unit: SourceUnit, context: RuleContext) -> [RuleViolation] {
    [RuleViolation(path: unit.path, lines: 2...4, message: "span")]
  }
}

@Suite("RuleEngine")
struct RuleEngineTests {
  private let context = RuleContext(scopes: StaticModuleScopes())

  private func run(
    _ text: String, path: String = "A.swift", rules: [any Rule] = [ForbiddenCallRule()],
    context: RuleContext? = nil, addedLines: [AddedLines]? = nil
  ) throws -> RuleRunResult {
    try RuleEngine(rules: rules).run(
      [SourceInput(path: path, text: text)], context: context ?? self.context,
      restrictTo: addedLines)
  }

  @Test("matches syntax, not text — catches string literals and comments tripping a rule")
  func syntaxNotText() throws {
    let result = try run(
      """
      let s = "forbidden()"
      // forbidden()
      /* forbidden() */
      forbidden()
      """)
    #expect(result.findings.map(\.line) == [4])
    #expect(result.findings.map(\.ruleID) == ["test.forbidden-call"])
  }

  @Test(
    "a same-line allow with a reason waives the finding and is counted — catches waivers lost from the report"
  )
  func allowWithReason() throws {
    let result = try run(
      """
      forbidden() // swiftgate:allow test.forbidden-call — fixture proves the waiver path
      forbidden() /* swiftgate:allow test.forbidden-call -- ASCII separator */
      """)
    #expect(result.findings.isEmpty)
    #expect(
      result.allowances == [
        Allowance(
          ruleID: "test.forbidden-call", path: "A.swift", line: 1,
          reason: "fixture proves the waiver path"),
        Allowance(
          ruleID: "test.forbidden-call", path: "A.swift", line: 2, reason: "ASCII separator"),
      ])
  }

  @Test("an allow on the line above does not waive — catches reasons drifting away from the code")
  func allowOnPreviousLine() throws {
    let result = try run(
      """
      // swiftgate:allow test.forbidden-call — reason on the wrong line
      forbidden()
      """)
    #expect(result.findings.map(\.line) == [2])
    #expect(result.allowances.isEmpty)
  }

  @Test(
    "an allow for a different rule does not waive — catches a waiver silencing every rule on a line"
  )
  func allowForOtherRule() throws {
    let result = try run("forbidden() // swiftgate:allow test.other — unrelated")
    #expect(result.findings.map(\.ruleID) == ["test.forbidden-call"])
  }

  @Test("a bare allow is itself a gating finding and waives nothing — catches reasonless waivers")
  func bareAllow() throws {
    let result = try run(
      """
      forbidden() // swiftgate:allow test.forbidden-call
      forbidden() // swiftgate:allow test.forbidden-call because I said so
      """)
    let byRule = Dictionary(grouping: result.findings, by: \.ruleID)
    #expect(byRule["test.forbidden-call"]?.map(\.line) == [1, 2])
    #expect(byRule[RuleEngine.allowMissingReasonRuleID]?.map(\.line) == [1, 2])
    #expect(byRule[RuleEngine.allowMissingReasonRuleID]?.allSatisfy(\.severity.failsGate) == true)
    #expect(result.allowances.isEmpty)
  }

  @Test(
    "a bare allow for a rule outside this run is left to the run that owns it — catches duplicate findings across commands"
  )
  func bareAllowForInactiveRule() throws {
    let result = try run("let x = 1 // swiftgate:allow safety.try-bang")
    #expect(result.findings.isEmpty)
  }

  @Test(
    "allow text inside a string literal is not a waiver — catches waivers smuggled through data")
  func allowInStringLiteral() throws {
    let result = try run(#"forbidden(); let s = "// swiftgate:allow test.forbidden-call — nope""#)
    #expect(result.findings.map(\.ruleID) == ["test.forbidden-call"])
  }

  @Test(
    "role-scoped rules skip files outside their roles and files of unknown module — catches Core-only bans firing in Live code"
  )
  func roleScope() throws {
    var rule = ForbiddenCallRule()
    rule.scope = .roles([.core])
    let scopes = StaticModuleScopes([
      .init(scope: ModuleScope(module: "PayCore", role: .core), directories: ["Core"]),
      .init(scope: ModuleScope(module: "PayLive", role: .clientLive), directories: ["Live"]),
    ])
    let engine = RuleEngine(rules: [rule])
    let result = try engine.run(
      [
        SourceInput(path: "Core/A.swift", text: "forbidden()"),
        SourceInput(path: "Live/A.swift", text: "forbidden()"),
        SourceInput(path: "Elsewhere/A.swift", text: "forbidden()"),
      ], context: RuleContext(scopes: scopes))
    #expect(result.findings.map(\.file) == ["Core/A.swift"])
  }

  @Test(
    "test-file scope includes files by role or by test-framework import — catches testlint skipping tests outside Tests/"
  )
  func testFileScope() throws {
    var rule = ForbiddenCallRule()
    rule.scope = .testFiles
    let result = try RuleEngine(rules: [rule]).run(
      [
        SourceInput(path: "Tests/PayTests/A.swift", text: "forbidden()"),
        SourceInput(path: "Loose/B.swift", text: "import Testing\nforbidden()"),
        SourceInput(path: "Loose/C.swift", text: "import XCTest\nforbidden()"),
        SourceInput(path: "Sources/PayCore/D.swift", text: "forbidden()"),
      ], context: RuleContext(scopes: PathConventionModuleScopes()))
    #expect(
      result.findings.map(\.file) == ["Loose/B.swift", "Loose/C.swift", "Tests/PayTests/A.swift"])
  }

  @Test(
    "added-line restriction keeps only findings touching added lines — catches pre-commit blocking on untouched code"
  )
  func addedLinesRestriction() throws {
    let text = "forbidden()\nforbidden()\nforbidden()\n"
    let result = try run(text, addedLines: [AddedLines(path: "A.swift", ranges: [2...2])])
    #expect(result.findings.map(\.line) == [2])

    let untouched = try run(text, addedLines: [AddedLines(path: "Other.swift", ranges: [1...3])])
    #expect(untouched.findings.isEmpty)
  }

  @Test(
    "a multi-line violation is reported at its first added line — catches block findings pointing at old lines"
  )
  func spanReportedAtFirstAddedLine() throws {
    let result = try run(
      "a\nb\nc\nd\ne\n", rules: [SpanRule()],
      addedLines: [AddedLines(path: "A.swift", ranges: [3...5])])
    #expect(result.findings.map(\.line) == [3])
    let outside = try run(
      "a\nb\nc\nd\ne\n", rules: [SpanRule()],
      addedLines: [AddedLines(path: "A.swift", ranges: [5...5])])
    #expect(outside.findings.isEmpty)
  }

  @Test("findings are ordered by file, line, then rule — catches nondeterministic report bytes")
  func ordering() throws {
    let result = try RuleEngine(rules: [SpanRule(), ForbiddenCallRule()]).run(
      [
        SourceInput(path: "B.swift", text: "forbidden()\nforbidden()"),
        SourceInput(path: "A.swift", text: "\nforbidden()"),
      ], context: context)
    #expect(
      result.findings.map { "\($0.file):\($0.line ?? 0):\($0.ruleID)" } == [
        "A.swift:2:test.forbidden-call", "A.swift:2:test.span",
        "B.swift:1:test.forbidden-call", "B.swift:2:test.forbidden-call", "B.swift:2:test.span",
      ])
  }
}

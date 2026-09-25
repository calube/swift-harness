import Foundation
import SwiftGateDomain
import SwiftGateRules
import Testing

/// Exact-line checks for each comment rule, over the rule's own fixtures, so a rule that fires on
/// only one of several seeded cases is caught.
@Suite("Comment rules")
struct CommentRulesTests {
  private func lines(
    _ ruleID: String, _ fixture: String, codenames: [String] = [],
    addedLines: [ClosedRange<Int>]? = nil
  ) throws -> [Int] {
    let rule = try #require(RuleCatalog.comments.first { $0.descriptor.id == ruleID })
    let file = RuleFixtureTests.fixturesRoot.appending(path: "\(ruleID)/\(fixture)")
    let input = SourceInput(path: "F.swift", text: try String(contentsOf: file, encoding: .utf8))
    let result = try RuleEngine(rules: [rule]).run(
      [input], context: RuleContext(scopes: StaticModuleScopes(), privateCodenames: codenames),
      restrictTo: addedLines.map { [AddedLines(path: "F.swift", ranges: $0)] })
    return result.findings.filter { $0.ruleID == ruleID }.compactMap(\.line)
  }

  @Test(
    "commented-out statements are blocked, prose with keywords, MARK, #warning and doc examples are not — catches dead code slipping in or prose blocked"
  )
  func commentedOutCode() throws {
    #expect(try lines("comments.commented-out-code", "bad/StatementBlock.swift") == [2])
    #expect(try lines("comments.commented-out-code", "bad/SingleCall.swift") == [2])
    #expect(try lines("comments.commented-out-code", "bad/MixedBlock.swift") == [3])
    #expect(try lines("comments.commented-out-code", "bad/BlockComment.swift") == [1])
    #expect(try lines("comments.commented-out-code", "bad/CompoundAssignment.swift") == [2])
    #expect(try lines("comments.commented-out-code", "good/ProseWithKeywords.swift") == [])
  }

  @Test(
    "history narration is blocked on every phrasing, adjective 'previously' is not — catches changelog prose in source"
  )
  func diffNarration() throws {
    #expect(try lines("comments.diff-narration", "bad/Narration.swift") == [1, 3, 5, 7, 9])
    #expect(try lines("comments.diff-narration", "good/Prose.swift") == [])
  }

  @Test(
    "line-number references are blocked in every form — catches references that drift on the next edit"
  )
  func lineReference() throws {
    #expect(try lines("comments.line-reference", "bad/LineNumbers.swift") == [1, 3, 5])
    #expect(try lines("comments.line-reference", "good/NoLineNumbers.swift") == [])
  }

  @Test(
    "TODO/FIXME need a URL, #number or tracker key; strings and #warning are ignored — catches orphaned TODOs"
  )
  func todoWithoutLink() throws {
    #expect(try lines("comments.todo-without-link", "bad/Todos.swift") == [1, 3])
    #expect(try lines("comments.todo-without-link", "good/LinkedTodos.swift") == [])
  }

  @Test(
    "local paths and configured codenames are blocked as whole words — catches private context leaking to reviewers"
  )
  func privateReference() throws {
    let codenames = ["Nightjar"]
    #expect(
      try lines("comments.private-reference", "bad/Paths.swift", codenames: codenames) == [1, 3, 5])
    #expect(
      try lines("comments.private-reference", "good/RepoRelative.swift", codenames: codenames) == []
    )
  }

  @Test(
    "suppressions and unsafe constructs need a same-line reason naming the right rule — catches silent escape hatches"
  )
  func unjustifiedSuppression() throws {
    #expect(
      try lines("comments.unjustified-suppression", "bad/Suppressions.swift")
        == [1, 2, 3, 4, 4, 5, 6, 7, 8, 9, 10])
    #expect(try lines("comments.unjustified-suppression", "good/Justified.swift") == [])
  }

  @Test(
    "pre-commit mode ignores suppressions on lines the change did not add — catches blocking commits on legacy code"
  )
  func suppressionOnlyOnAddedLines() throws {
    #expect(
      try lines("comments.unjustified-suppression", "bad/Suppressions.swift", addedLines: [3...3])
        == [3])
  }

  @Test(
    "comment blocks over 3 lines warn, file headers and doc contracts do not — catches essays in code"
  )
  func longBlock() throws {
    #expect(try lines("comments.long-block", "bad/Essay.swift") == [2])
    #expect(try lines("comments.long-block", "good/ShortAndHeader.swift") == [])
  }

  @Test(
    "comments restating the if/guard/return below warn, why-comments do not — catches noise comments"
  )
  func restatesCode() throws {
    #expect(try lines("comments.restates-code", "bad/Restates.swift") == [2, 4, 6])
    #expect(try lines("comments.restates-code", "good/Why.swift") == [])
  }

  @Test(
    "comments inside Swift Testing and XCTest bodies warn, helpers and directives do not — catches arrange/act/assert labels"
  )
  func testBody() throws {
    #expect(try lines("comments.test-body", "bad/ArrangeActAssert.swift") == [5, 7, 9])
    #expect(try lines("comments.test-body", "bad/XCTestBody.swift") == [5])
    #expect(try lines("comments.test-body", "good/NamedTests.swift") == [])
  }

  @Test(
    "/// on trivial private declarations warns, contracts and non-trivial privates do not — catches doc noise"
  )
  func trivialPrivateDoc() throws {
    #expect(try lines("comments.trivial-private-doc", "bad/TrivialDocs.swift") == [2, 5])
    #expect(try lines("comments.trivial-private-doc", "good/PublicContracts.swift") == [])
  }

  @Test("AI-prose tells warn; a single em dash and allow separators do not — catches filler prose")
  func aiProse() throws {
    #expect(try lines("comments.ai-prose", "bad/Tells.swift") == [1, 3, 5, 7])
    #expect(try lines("comments.ai-prose", "good/Plain.swift") == [])
  }

  @Test("blocking rules gate and warning rules never do — catches heuristics blocking commits")
  func severities() {
    let blocking = Set(
      RuleCatalog.comments.filter(\.descriptor.severity.failsGate).map(\.descriptor.id))
    #expect(
      blocking == [
        "comments.commented-out-code", "comments.diff-narration", "comments.line-reference",
        "comments.todo-without-link", "comments.private-reference",
        "comments.unjustified-suppression",
      ])
  }
}

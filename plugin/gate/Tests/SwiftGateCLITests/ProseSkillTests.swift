import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// The drafter applies `skills/prose` before `swiftgate prose` gates its draft. A rule the gate
/// enforces but the skill never teaches turns every draft into a guessing loop, and a skill that
/// fails its own rules teaches by bad example.
@Suite("prose skill mirrors swiftgate prose")
struct ProseSkillTests {
  static let path = "skills/prose/SKILL.md"

  static func skill() throws -> String {
    try String(contentsOf: Fixture.checkoutRoot.appending(path: path), encoding: .utf8)
  }

  @Test(
    "every prose rule id appears in the skill — catches the skill and the gate drifting apart when a rule is added or renamed"
  )
  func everyRuleIDAppears() throws {
    let text = try Self.skill()
    let missing = ProseRule.allCases.map(\.id).filter { !text.contains("`\($0)`") }
    #expect(missing == [])
  }

  @Test(
    "the skill quotes the configurable sentence ceiling and its default — catches a changed default the skill still teaches"
  )
  func quotesCeiling() throws {
    let text = try Self.skill()
    #expect(text.contains("`[docs] sentence_ceiling`"))
    #expect(text.contains("\(DocsConfig.defaultSentenceCeiling) words"))
  }

  @Test(
    "the skill passes its own prose rules — catches a skill whose running text breaks the rules it teaches"
  )
  func passesOwnRules() throws {
    let findings = try ProseRules.check(
      Self.skill(), file: Self.path, sentenceCeiling: DocsConfig.defaultSentenceCeiling)
    #expect(findings.map { "\($0.line ?? 0) \($0.ruleID) \($0.message)" } == [])
  }
}

import Foundation
import SwiftGateTestSupport
import Testing

/// Reviewer agents and skills cite standards by rule id; a reviewer told to check a rule that
/// doesn't exist either invents one or cites the wrong one, and its finding can't be verified.
@Suite("rule anchors cited by agents and skills")
struct RuleAnchorTests {
  /// Rule-id families in `docs/standards.md` and `P` in `docs/testing-playbook.md`. `T0`–`T3` are
  /// tiers, not rules, so `T` is deliberately absent.
  static func citations(in text: String) -> [String] {
    text.matches(of: /(?:^|[^A-Za-z0-9_-])([ACDEGHKOPUX][0-9]{1,2})\b/).map { String($0.1) }
  }

  static func text(_ relative: String) throws -> String {
    try String(contentsOf: Fixture.pluginRoot.appending(path: relative), encoding: .utf8)
  }

  /// Every rule a standards doc defines, from its `**<id>. Title.**` headings.
  static func defined() throws -> Set<String> {
    let docs = try text("docs/standards.md") + "\n" + text("docs/testing-playbook.md")
    return Set(docs.matches(of: /(?m)^\*\*([A-Z][0-9]{1,2})\./).map { String($0.1) })
  }

  static func citingFiles() throws -> [String] {
    let root = Fixture.pluginRoot
    let agents = try FileManager.default.contentsOfDirectory(
      atPath: root.appending(path: "agents").path
    ).filter { $0.hasSuffix(".md") }.map { "agents/\($0)" }
    let skills = try FileManager.default.contentsOfDirectory(
      atPath: root.appending(path: "skills").path
    ).map { "skills/\($0)/SKILL.md" }.filter {
      FileManager.default.fileExists(atPath: root.appending(path: $0).path)
    }
    return (agents + skills).sorted()
  }

  @Test(
    "every rule id cited in agents and skills is defined in the standards or the playbook — catches a reviewer rubric pointing at a rule that doesn't exist"
  )
  func citedRulesExist() throws {
    let defined = try Self.defined()
    let files = try Self.citingFiles()
    #expect(files.contains("agents/architecture.md"))
    #expect(files.contains("skills/review/SKILL.md"))
    var dangling: [String] = []
    for file in files {
      for id in try Self.citations(in: Self.text(file)) where !defined.contains(id) {
        dangling.append("\(file): \(id)")
      }
    }
    #expect(dangling == [])
  }

  @Test(
    "the anchor scan finds the rule families it guards — catches a regex change that silently matches nothing"
  )
  func scanSeesKnownRules() throws {
    let defined = try Self.defined()
    #expect(
      defined.isSuperset(of: ["C1", "A5", "D2", "E1", "O1", "U1", "X1", "G1", "K1", "H1", "P11"]))
    #expect(try Self.citations(in: Self.text("agents/architecture.md")).contains("A5"))
    #expect(Self.citations(in: "git diff -U5 and T1, cites D2, P5") == ["D2", "P5"])
  }
}

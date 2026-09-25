import Foundation
import SwiftGateDomain
import Testing

@Suite("Design lint — sections and ids")
struct DesignLintSectionsTests {
  static let fixturesRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Fixtures/design/sections", directoryHint: .isDirectory)

  static func fixture(_ name: String) throws -> DesignDocument {
    let text = try String(contentsOf: fixturesRoot.appending(path: name), encoding: .utf8)
    return DesignDocument(markdown: MarkdownDocument.parse(text))
  }

  static func parse(_ text: String) -> DesignDocument {
    DesignDocument(markdown: MarkdownDocument.parse(text))
  }

  static func check(
    _ document: DesignDocument, otherDesignIds: Set<String> = []
  ) throws -> [Finding] {
    try DesignLintSections.check(
      document: document, docPath: "docs/example/designs/x.md", otherDesignIds: otherDesignIds)
  }

  // MARK: - The full, valid fixture stays clean

  @Test(
    "a complete, spec-compliant design doc has no section or id findings — catches the baseline fixture regressing to a violation"
  )
  func completeDesignIsClean() throws {
    let findings = try Self.check(try Self.fixture("complete.md"))
    #expect(findings == [])
  }

  // MARK: - The required order is one shared source of truth

  @Test(
    "the lint's required section order is exactly DesignDocument's own RequiredSection order — catches the two copies drifting apart"
  )
  func requiredOrderMatchesDesignDocumentModel() {
    let expected = [
      "problem", "requirements", "evidence", "options", "decision", "architecture",
      "module-kinds", "test-plan-by-tier", "observability", "perf--scale", "risks",
      "open-questions", "changelog",
    ]
    #expect(DesignDocument.RequiredSection.allCases.map(\.anchor) == expected)
  }

  // MARK: - §5.3 section presence and order

  @Test(
    "a design doc missing Risks is flagged, naming only that section — catches a dropped §5.3 section"
  )
  func missingRiskIsFlagged() throws {
    let findings = try Self.check(try Self.fixture("missing-risks.md"))
    let missing = findings.filter { $0.ruleID == "design-lint.section-missing" }
    #expect(missing.count == 1)
    #expect(missing.first?.message.contains("Risks") == true)
  }

  @Test(
    "sections present out of §5.3 order are flagged — catches a reordered template slipping past review"
  )
  func sectionsOutOfOrderAreFlagged() throws {
    let findings = try Self.check(try Self.fixture("out-of-order.md"))
    #expect(findings.contains { $0.ruleID == "design-lint.section-order" })
    // Every §5.3 section is still present in this fixture, just reordered.
    #expect(findings.filter { $0.ruleID == "design-lint.section-missing" } == [])
  }

  @Test(
    "a heading-shaped line inside a fenced block never registers as a section — catches a fenced example truncating or duplicating the structure check"
  )
  func headingInsideFenceIsNotASectionBoundary() throws {
    let findings = try Self.check(try Self.fixture("heading-in-fence.md"))
    #expect(findings == [])
  }

  @Test(
    "a required section with an extra subsection of its own is still just \"present\" — catches a nested heading being mistaken for a missing or reordered top-level section"
  )
  func extraSubsectionDoesNotConfuseStructure() throws {
    let findings = try Self.check(try Self.fixture("extra-subsections.md"))
    #expect(findings == [])
  }

  @Test(
    "a CRLF design doc parses and lints the same as its LF twin — catches the section scan splitting mid-line on \\r\\n"
  )
  func crlfDesignIsClean() throws {
    let findings = try Self.check(try Self.fixture("crlf.md"))
    #expect(findings == [])
  }

  // MARK: - Problem non-empty

  @Test("an empty Problem section is flagged — catches a template Problem heading left unfilled")
  func emptyProblemIsFlagged() throws {
    let text = """
      ## Problem

      ## Requirements

      - req-some-real-requirement: a statement.
      """
    let findings = try Self.check(Self.parse(text))
    #expect(findings.contains { $0.ruleID == "design-lint.problem-empty" })
  }

  // MARK: - Requirement and test-plan id form (spec §5.1 / D18)

  @Test(
    "a requirement id shorter than 3 kebab words is flagged — catches an id too vague to be a machine key"
  )
  func shortRequirementIDIsFlagged() throws {
    let text = """
      ## Requirements

      - req-too-short: a statement.
      """
    let findings = try Self.check(Self.parse(text))
    let finding = try #require(
      findings.first { $0.ruleID == "design-lint.requirement-id-form" })
    #expect(finding.message.contains("req-too-short"))
  }

  @Test(
    "a test-plan id shorter than 3 kebab words is flagged — catches an id too vague to be a machine key"
  )
  func shortTestPlanIDIsFlagged() throws {
    let text = """
      ## Test plan by tier

      - test-too-short: a behaviour — tier T1
      """
    let findings = try Self.check(Self.parse(text))
    let finding = try #require(findings.first { $0.ruleID == "design-lint.test-id-form" })
    #expect(finding.message.contains("test-too-short"))
  }

  // MARK: - Repo-unique ids (known ids as input)

  @Test(
    "a requirement id also defined by another design is flagged — catches an id reused across designs instead of staying repo-unique"
  )
  func requirementIDDuplicatedAcrossDesignsIsFlagged() throws {
    let text = """
      ## Requirements

      - req-offline-queue-drains-on-reconnect: a statement.
      """
    let findings = try Self.check(
      Self.parse(text), otherDesignIds: ["req-offline-queue-drains-on-reconnect"])
    let finding = try #require(
      findings.first { $0.ruleID == "design-lint.requirement-id-duplicate" })
    #expect(finding.message.contains("req-offline-queue-drains-on-reconnect"))
  }

  @Test(
    "the same id defined twice inside one design is flagged — catches a copy-pasted requirement bullet"
  )
  func requirementIDDuplicatedWithinDocIsFlagged() throws {
    let text = """
      ## Requirements

      - req-offline-queue-drains-on-reconnect: first statement.
      - req-offline-queue-drains-on-reconnect: second statement.
      """
    let findings = try Self.check(Self.parse(text))
    let duplicates = findings.filter { $0.ruleID == "design-lint.requirement-id-duplicate" }
    #expect(duplicates.count == 1)
  }

  @Test(
    "another design's id merely referenced in this doc's prose is not flagged — catches a citation being mistaken for a redefinition"
  )
  func referencingAnotherDesignsIDIsNotFlagged() throws {
    let text = """
      ## Requirements

      - req-this-designs-own-requirement: a statement.
      """
    // "req-defined-in-another-design" is known elsewhere but never *defined* in this doc's
    // Requirements/Test plan bullets, so it must never surface as a duplicate here.
    let findings = try Self.check(
      Self.parse(text), otherDesignIds: ["req-defined-in-another-design"])
    #expect(findings.filter { $0.ruleID == "design-lint.requirement-id-duplicate" } == [])
  }

  @Test(
    "an id-shaped token inside inline code is never read as a second definition — catches prose mentioning an id being mistaken for defining it"
  )
  func idShapedTokenInsideInlineCodeIsNotFlagged() throws {
    let text = """
      ## Requirements

      - req-offline-queue-drains-on-reconnect: submits once connectivity returns; \
      see `req-some-other-designs-id` for prior art.
      """
    let findings = try Self.check(
      Self.parse(text), otherDesignIds: ["req-some-other-designs-id"])
    #expect(findings.filter { $0.ruleID.hasPrefix("design-lint.requirement-id") } == [])
  }

  // MARK: - Test plan tiers

  @Test("a test-plan item with no tier is flagged — catches a bullet missing \" — tier \"")
  func testItemWithoutTierIsFlagged() throws {
    let text = """
      ## Test plan by tier

      - test-queued-orders-replay-in-submit-order: a queued order resubmits after reconnect
      """
    let findings = try Self.check(Self.parse(text))
    let finding = try #require(findings.first { $0.ruleID == "design-lint.test-tier-invalid" })
    #expect(finding.message.contains("no tier"))
  }

  @Test(
    "a test-plan item with a tier outside T1–T3 is flagged — catches a stray T0 or a typo'd tier"
  )
  func testItemWithUnrecognisedTierIsFlagged() throws {
    let text = """
      ## Test plan by tier

      - test-queued-orders-replay-in-submit-order: a queued order resubmits after reconnect — tier T0
      """
    let findings = try Self.check(Self.parse(text))
    let finding = try #require(findings.first { $0.ruleID == "design-lint.test-tier-invalid" })
    #expect(finding.message.contains("T0"))
  }

  @Test("tiers T1, T2 and T3 are all accepted — catches a valid tier being flagged")
  func recognisedTiersAreNotFlagged() throws {
    let text = """
      ## Test plan by tier

      - test-one-behaviour-here: a behaviour — tier T1
      - test-two-behaviour-here: a behaviour — tier T2
      - test-three-behaviour-here: a behaviour — tier T3
      """
    let findings = try Self.check(Self.parse(text))
    #expect(findings.filter { $0.ruleID == "design-lint.test-tier-invalid" } == [])
  }

  // MARK: - Options count (2–3)

  @Test("Options with only 1 entry is flagged — catches an under-explored decision")
  func oneOptionIsFlagged() throws {
    let text = """
      ## Options

      ### Option 1: Only choice

      Trade-offs: none considered.
      """
    let findings = try Self.check(Self.parse(text))
    #expect(findings.contains { $0.ruleID == "design-lint.options-count" })
  }

  @Test("Options with 2 entries is not flagged")
  func twoOptionsIsNotFlagged() throws {
    let text = """
      ## Options

      ### Option 1: First

      Trade-offs: a.

      ### Option 2: Second

      Trade-offs: b.
      """
    let findings = try Self.check(Self.parse(text))
    #expect(findings.filter { $0.ruleID == "design-lint.options-count" } == [])
  }

  @Test("Options with 3 entries is not flagged")
  func threeOptionsIsNotFlagged() throws {
    let text = """
      ## Options

      ### Option 1: First

      Trade-offs: a.

      ### Option 2: Second

      Trade-offs: b.

      ### Option 3: Third

      Trade-offs: c.
      """
    let findings = try Self.check(Self.parse(text))
    #expect(findings.filter { $0.ruleID == "design-lint.options-count" } == [])
  }

  @Test("Options with 4 entries is flagged — catches an under-narrowed decision")
  func fourOptionsIsFlagged() throws {
    let text = """
      ## Options

      ### Option 1: First

      Trade-offs: a.

      ### Option 2: Second

      Trade-offs: b.

      ### Option 3: Third

      Trade-offs: c.

      ### Option 4: Fourth

      Trade-offs: d.
      """
    let findings = try Self.check(Self.parse(text))
    let finding = try #require(findings.first { $0.ruleID == "design-lint.options-count" })
    #expect(finding.message.contains("4"))
  }

  // MARK: - Module kinds from the standards model

  @Test(
    "a Module kinds row naming a kind outside the standards model is flagged, naming the module — catches an invented kind bypassing the closed set"
  )
  func unknownModuleKindIsFlagged() throws {
    let text = """
      ## Module kinds

      | Module | Kind | Reason |
      |---|---|---|
      | OrderQueueCore | core | pure queue model, no I/O |
      """
    let findings = try Self.check(Self.parse(text))
    let finding = try #require(findings.first { $0.ruleID == "design-lint.module-kind-unknown" })
    #expect(finding.message.contains("OrderQueueCore"))
    #expect(finding.message.contains("core"))
  }

  @Test("every standards-model kind is accepted — catches a recognised kind being flagged")
  func everyKnownModuleKindIsAccepted() throws {
    let text = """
      ## Module kinds

      | Module | Kind | Reason |
      |---|---|---|
      | A | feature | x |
      | B | engine | x |
      | C | render | x |
      | D | library | x |
      | E | client | x |
      | F | test-support | x |
      """
    let findings = try Self.check(Self.parse(text))
    #expect(findings.filter { $0.ruleID == "design-lint.module-kind-unknown" } == [])
  }

  // MARK: - Findings carry rule ids and a locatable file

  @Test("every finding names its rule id and the design doc's path")
  func findingsCarryRuleIDAndPath() throws {
    let findings = try Self.check(try Self.fixture("missing-risks.md"))
    for finding in findings {
      #expect(!finding.ruleID.isEmpty)
      #expect(finding.file == "docs/example/designs/x.md")
    }
  }
}

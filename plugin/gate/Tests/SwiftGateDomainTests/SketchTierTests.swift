import Foundation
import SwiftGateDomain
import Testing

/// Spec §9's `sketch` design tier: a spec that already states what to build, so no research lane
/// checks its claims. `design-scope` never recommends it, and `design-lint` lifts exactly one rule
/// for a doc whose frontmatter names it.
@Suite("sketch design tier")
struct SketchTierTests {
  // MARK: - DesignTier gains sketch, closed and reviewer-free

  @Test("sketch is a DesignTier case decodable from its raw value, like every other tier")
  func sketchIsAKnownDesignTierCase() {
    #expect(DesignTier.allCases.contains(.sketch))
    #expect(DesignTier(rawValue: "sketch") == .sketch)
  }

  @Test(
    "sketch runs no review agents, the same as quick — catches review-synth gating on a reviewer sketch never runs"
  )
  func sketchRequiresNoReviewers() {
    #expect(DesignTier.sketch.requiredReviewers == [])
    #expect(DesignTier.sketch.requiredReviewers == DesignTier.quick.requiredReviewers)
  }

  // MARK: - design-scope never recommends sketch, over a spread of frame answers

  private static func facts(
    addsDependency: Bool, addsModuleKind: Bool, modulesAdded: Int, modulesTouched: Int
  ) -> DesignScopeGraphFacts {
    DesignScopeGraphFacts(
      addsDependency: addsDependency, addsModuleKind: addsModuleKind, modulesAdded: modulesAdded,
      modulesTouched: modulesTouched)
  }

  /// Every boolean combination crossed with module counts at and around both deep thresholds —
  /// the same spread `DesignScopeTests` uses for its own safety property, so this isn't checked on
  /// one hand-picked input.
  private static let spread: [DesignScopeGraphFacts] = {
    let counts = [0, 1, 2, 3, 4, 5]
    var facts: [DesignScopeGraphFacts] = []
    for addsDependency in [false, true] {
      for addsModuleKind in [false, true] {
        for added in counts {
          for touched in counts where touched >= added {
            facts.append(
              Self.facts(
                addsDependency: addsDependency, addsModuleKind: addsModuleKind,
                modulesAdded: added, modulesTouched: touched))
          }
        }
      }
    }
    return facts
  }()

  @Test(
    "design-scope never recommends sketch, for any combination of frame-answer facts — catches sketch leaking into the automatic recommendation",
    arguments: spread)
  func designScopeNeverRecommendsSketch(_ facts: DesignScopeGraphFacts) {
    #expect(DesignScope.recommend(facts).tier != .sketch)
  }

  // MARK: - design-lint: sketch relaxes exactly one rule, only in Decision

  private static func doc(tier: String?, decision: String, extraSections: String = "")
    -> DesignDocument
  {
    let frontmatter = tier.map { "---\ntier: \($0)\n---\n" } ?? ""
    let text = """
      \(frontmatter)## Decision

      \(decision)
      \(extraSections)
      """
    return DesignDocument(markdown: MarkdownDocument.parse(text))
  }

  private static func check(_ document: DesignDocument) throws -> [Finding] {
    try DesignLintEvidence.check(
      document: document, docPath: "docs/example/designs/x.md", claims: [])
  }

  @Test(
    "an [UNVERIFIED] Decision bullet with no Risks mirror passes at tier sketch — spec §9's relaxation"
  )
  func unverifiedDecisionBulletPassesAtSketch() throws {
    let document = Self.doc(
      tier: "sketch", decision: "- Use the queue-backed approach [UNVERIFIED]")
    let findings = try Self.check(document)
    #expect(findings.filter { $0.ruleID == "design-lint.unverified-in-decision" } == [])
    #expect(findings.filter { $0.ruleID == "design-lint.unverified-uncovered" } == [])
  }

  @Test(
    "the same [UNVERIFIED] Decision bullet with no Risks mirror fails at every other tier — catches the sketch relaxation leaking",
    arguments: [nil, "quick", "standard", "deep"])
  func unverifiedDecisionBulletFailsOutsideSketch(tier: String?) throws {
    let document = Self.doc(tier: tier, decision: "- Use the queue-backed approach [UNVERIFIED]")
    let findings = try Self.check(document)
    #expect(findings.contains { $0.ruleID == "design-lint.unverified-in-decision" })
    #expect(findings.contains { $0.ruleID == "design-lint.unverified-uncovered" })
  }

  @Test(
    "sketch's relaxation is scoped to Decision: an [UNVERIFIED] Evidence bullet with no Risks mirror still fails at sketch"
  )
  func unverifiedEvidenceBulletStillFailsAtSketch() throws {
    let text = """
      ---
      tier: sketch
      ---
      ## Evidence

      - [UNVERIFIED] a fact nobody checked

      ## Decision

      - Use the queue-backed approach [ev-unrelated]
      """
    let document = DesignDocument(markdown: MarkdownDocument.parse(text))
    let findings = try Self.check(document)
    #expect(findings.contains { $0.ruleID == "design-lint.unverified-uncovered" })
  }

  @Test(
    "sketch does not relax the supported-citation rule: a Decision bullet citing a refuted claim still fails"
  )
  func citationNotSupportedStillFailsAtSketch() throws {
    let document = Self.doc(
      tier: "sketch", decision: "- Use the queue-backed approach [ev-refuted]")
    let findings = try DesignLintEvidence.check(
      document: document, docPath: "docs/example/designs/x.md",
      claims: [
        Claim(
          id: "ev-refuted", lane: "test-lane", text: "a claim used in tests",
          citation: Citation(kind: .file, loc: "docs/example.md#L1-L2", pin: "abc123", quote: "x"),
          status: .refuted)
      ])
    #expect(findings.contains { $0.ruleID == "design-lint.citation-not-supported" })
  }

  @Test(
    "an unrecognised frontmatter tier is a lint finding, not a crash, and doesn't relax Decision's rules"
  )
  func unknownTierIsAFindingNotACrash() throws {
    let document = Self.doc(tier: "quik", decision: "- Use the queue-backed approach [UNVERIFIED]")
    let findings = try Self.check(document)
    let unknown = try #require(findings.first { $0.ruleID == "design-lint.unknown-tier" })
    #expect(unknown.message.contains("quik"))
    #expect(unknown.message.contains("sketch"))
    // An unknown tier must read as "no tier," never as sketch's relaxed rules.
    #expect(findings.contains { $0.ruleID == "design-lint.unverified-in-decision" })
    #expect(findings.contains { $0.ruleID == "design-lint.unverified-uncovered" })
  }

  @Test("no frontmatter tier at all reports no unknown-tier finding")
  func noTierReportsNoUnknownTierFinding() throws {
    let document = Self.doc(tier: nil, decision: "- Use the queue-backed approach [UNVERIFIED]")
    let findings = try Self.check(document)
    #expect(findings.filter { $0.ruleID == "design-lint.unknown-tier" } == [])
  }
}

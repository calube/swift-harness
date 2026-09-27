import Foundation
import SwiftGateDomain
import Testing

/// Spec §9's `sketch` design tier: a spec that already states what to build, so no research lane
/// checks its claims. `design-scope` never recommends it, and `design-lint` relaxes Decision and
/// Perf & scale for a doc whose frontmatter names it.
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

  // MARK: - design-lint: what sketch relaxes, and only at sketch

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

  private static func claim(_ id: String, kind: Citation.Kind, status: Claim.Status) -> Claim {
    Claim(
      id: id, lane: "prior-decisions", text: "a claim used in tests",
      citation: kind == .answer
        ? Citation(kind: .answer, loc: "answers.jsonl#design-run/1", quote: "Which area?")
        : Citation(kind: kind, loc: "docs/example.md#L1-L2", pin: "abc123", quote: "x"),
      status: status)
  }

  private static func decisionCiting(_ claim: Claim, tier: String?) throws -> [Finding] {
    try DesignLintEvidence.check(
      document: Self.doc(tier: tier, decision: "- Load both sections at once [\(claim.id)]"),
      docPath: "docs/example/designs/x.md", claims: [claim]
    ).filter { $0.ruleID == "design-lint.citation-not-supported" }
  }

  @Test(
    "at sketch a Decision may cite the user's own frame answer once evidence check found its quote — catches the user's choices being unciteable because sketch runs no claim checker"
  )
  func quoteOkAnswerClaimBacksDecisionAtSketch() throws {
    let answer = Self.claim("ev-user-picks-both", kind: .answer, status: .quoteOk)
    #expect(try Self.decisionCiting(answer, tier: "sketch") == [])
  }

  @Test(
    "outside sketch a quote-ok answer claim still needs the claim checker — catches the sketch rule leaking to tiers that run a checker",
    arguments: [nil, "quick", "standard", "deep"])
  func quoteOkAnswerClaimStillFailsOutsideSketch(tier: String?) throws {
    let answer = Self.claim("ev-user-picks-both", kind: .answer, status: .quoteOk)
    #expect(try Self.decisionCiting(answer, tier: tier).count == 1)
  }

  @Test(
    "at sketch only a checked answer counts: a new answer claim, or a quote-ok claim of any other kind, still fails — catches sketch trusting research no one verified",
    arguments: [
      (Citation.Kind.answer, Claim.Status.new), (.file, .quoteOk), (.snapshot, .quoteOk),
      (.capture, .quoteOk),
    ])
  func onlyQuoteOkAnswerClaimsRelaxAtSketch(kind: Citation.Kind, status: Claim.Status) throws {
    #expect(
      try Self.decisionCiting(Self.claim("ev-other", kind: kind, status: status), tier: "sketch")
        .count == 1)
  }

  private static func perfDoc(tier: String?) -> DesignDocument {
    Self.doc(
      tier: tier, decision: "- Use the queue-backed approach [UNVERIFIED]",
      extraSections: """

        ## Perf & scale

        - throughput: 1 request per open [UNVERIFIED]
        """)
  }

  @Test(
    "at sketch an [UNVERIFIED] Perf & scale bullet needs no Risks mirror — catches every perf bullet being copied into Risks, since sketch has nothing to cite"
  )
  func unverifiedPerfBulletPassesAtSketch() throws {
    let findings = try Self.check(Self.perfDoc(tier: "sketch"))
    #expect(findings.filter { $0.ruleID == "design-lint.unverified-uncovered" } == [])
  }

  @Test(
    "outside sketch an [UNVERIFIED] Perf & scale bullet still needs its Risks mirror — catches the relaxation leaking",
    arguments: [nil, "quick", "standard", "deep"])
  func unverifiedPerfBulletFailsOutsideSketch(tier: String?) throws {
    let findings = try Self.check(Self.perfDoc(tier: tier))
    #expect(
      findings.contains {
        $0.ruleID == "design-lint.unverified-uncovered" && $0.message.contains("throughput")
      })
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

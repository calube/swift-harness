import Foundation
import SwiftGateDomain
import Testing

@Suite("Design lint — evidence tags")
struct DesignLintEvidenceTests {
  static let fixturesRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Fixtures/design", directoryHint: .isDirectory)

  static func parse(_ text: String) -> DesignDocument {
    DesignDocument(markdown: MarkdownDocument.parse(text))
  }

  static func fixture(_ name: String) throws -> DesignDocument {
    let text = try String(
      contentsOf: fixturesRoot.appending(path: name), encoding: .utf8)
    return DesignDocument(markdown: MarkdownDocument.parse(text))
  }

  static func check(_ document: DesignDocument, claims: [Claim] = []) throws -> [Finding] {
    try DesignLintEvidence.check(
      document: document, docPath: "docs/example/designs/x.md", claims: claims)
  }

  static func claim(id: String, status: Claim.Status) -> Claim {
    Claim(
      id: id, lane: "test-lane", text: "a claim used in tests",
      citation: Citation(kind: .file, loc: "docs/example.md#L1-L2", pin: "abc123", quote: "text"),
      status: status)
  }

  /// A minimal but fully-tagged design doc: one supported claim cited from Evidence, Decision and
  /// Perf & scale, all seven Perf dimensions named, and no `[UNVERIFIED]` tags — the baseline every
  /// negative test perturbs one piece of.
  static let supportedClaimID = "ev-supported-claim"

  static func wellFormedDoc(perfOverride: String? = nil) -> String {
    let perf =
      perfOverride
        ?? """
        - throughput: 100 req/s per instance [\(supportedClaimID)]
        - tail latency: p99 under 200ms [\(supportedClaimID)]
        - fan-out: one worker per shard [\(supportedClaimID)]
        - failure isolation: one shard failing doesn't affect others [\(supportedClaimID)]
        - resources: bounded to 4 workers per host [\(supportedClaimID)]
        - backpressure: queue rejects once full [\(supportedClaimID)]
        - 10×: still within budget at 10x load [\(supportedClaimID)]
        """
    return """
      ## Evidence

      - [\(supportedClaimID)] the underlying fact this design relies on.

      ## Decision

      - Use the queue-backed approach [\(supportedClaimID)]

      ## Perf & scale

      \(perf)

      ## Risks

      - Some risk worth tracking.

      ## Open questions

      - Some open question worth tracking.
      """
  }

  static let wellFormedClaims: [Claim] = [claim(id: supportedClaimID, status: .supported)]

  // MARK: - Untagged bullets

  @Test(
    "an untagged Decision bullet is flagged — catches a decision reaching the doc with no citation")
  func untaggedDecisionBulletIsFlagged() throws {
    let text = """
      ## Decision

      - Use the queue-backed approach because it's simpler
      """
    let findings = try Self.check(Self.parse(text))
    #expect(findings.contains { $0.ruleID == "design-lint.untagged-bullet" })
  }

  @Test("an untagged Evidence bullet is flagged")
  func untaggedEvidenceBulletIsFlagged() throws {
    let text = """
      ## Evidence

      - a fact with no tag at all
      """
    let findings = try Self.check(Self.parse(text))
    #expect(findings.contains { $0.ruleID == "design-lint.untagged-bullet" })
  }

  @Test("an untagged Perf & scale bullet is flagged")
  func untaggedPerfBulletIsFlagged() throws {
    let text = """
      ## Perf & scale

      - throughput: 100 req/s, no citation at all
      """
    let findings = try Self.check(Self.parse(text))
    #expect(findings.contains { $0.ruleID == "design-lint.untagged-bullet" })
  }

  @Test("a fully tagged well-formed doc has no untagged-bullet findings")
  func wellFormedDocHasNoUntaggedFindings() throws {
    let findings = try Self.check(Self.parse(Self.wellFormedDoc()), claims: Self.wellFormedClaims)
    #expect(findings.filter { $0.ruleID == "design-lint.untagged-bullet" } == [])
  }

  @Test("a fully tagged, fully supported, fully covered doc has zero findings")
  func wellFormedDocHasNoFindingsAtAll() throws {
    let findings = try Self.check(Self.parse(Self.wellFormedDoc()), claims: Self.wellFormedClaims)
    #expect(findings == [])
  }

  // MARK: - Citation of a non-supported claim in Decision

  @Test(
    "Decision citing a claim in any non-supported status is flagged — catches a lie or an unfinished check reaching Decision",
    arguments: Claim.Status.allCases.filter { $0 != .supported })
  func decisionCitingNonSupportedClaimIsFlagged(status: Claim.Status) throws {
    let text = """
      ## Decision

      - Use the queue-backed approach [ev-shaky-claim]
      """
    let findings = try Self.check(
      Self.parse(text), claims: [Self.claim(id: "ev-shaky-claim", status: status)])
    let finding = try #require(
      findings.first { $0.ruleID == "design-lint.citation-not-supported" })
    #expect(finding.severity == .major)
    #expect(finding.severity.failsGate)
    // A non-supported citation is never also reported as unknown — the ids differ.
    #expect(findings.contains { $0.ruleID == "design-lint.unknown-claim" } == false)
  }

  @Test("Decision citing a supported claim is not flagged")
  func decisionCitingSupportedClaimIsNotFlagged() throws {
    let text = """
      ## Decision

      - Use the queue-backed approach [ev-good-claim]
      """
    let findings = try Self.check(
      Self.parse(text), claims: [Self.claim(id: "ev-good-claim", status: .supported)])
    #expect(
      findings.filter {
        $0.ruleID.hasPrefix("design-lint.citation") || $0.ruleID.hasPrefix("design-lint.unknown")
      } == [])
  }

  @Test(
    "Evidence citing a non-supported claim is not flagged — only Decision requires 'supported'"
  )
  func evidenceCitingNonSupportedClaimIsNotFlagged() throws {
    let text = """
      ## Evidence

      - a fact still being checked [ev-in-progress]
      """
    let findings = try Self.check(
      Self.parse(text), claims: [Self.claim(id: "ev-in-progress", status: .new)])
    #expect(findings.filter { $0.ruleID == "design-lint.citation-not-supported" } == [])
  }

  // MARK: - Unknown claim id

  @Test(
    "citing an id that doesn't exist in the claims list is flagged with a rule id distinct from a non-supported citation"
  )
  func unknownClaimIDIsFlaggedDistinctly() throws {
    let text = """
      ## Decision

      - Use the queue-backed approach [ev-never-captured]
      """
    let findings = try Self.check(Self.parse(text), claims: [])
    let finding = try #require(findings.first { $0.ruleID == "design-lint.unknown-claim" })
    #expect(finding.message.contains("ev-never-captured"))
    #expect(findings.contains { $0.ruleID == "design-lint.citation-not-supported" } == false)
  }

  // MARK: - [UNVERIFIED] coverage in Risks / Open questions

  @Test(
    "an [UNVERIFIED] bullet with both Risks and Open questions empty is flagged — catches an unverified claim that never surfaces as a risk"
  )
  func unverifiedMissingFromRisksIsFlagged() throws {
    let findings = try Self.check(try Self.fixture("evidence/unverified-uncovered.md"))
    #expect(findings.contains { $0.ruleID == "design-lint.unverified-uncovered" })
  }

  @Test("an [UNVERIFIED] bullet with no Risks or Open questions sections at all is flagged")
  func unverifiedWithNoRisksOrOpenQuestionsSectionsIsFlagged() throws {
    let text = """
      ## Evidence

      - [UNVERIFIED] the underlying claim text
      """
    let findings = try Self.check(Self.parse(text))
    #expect(findings.contains { $0.ruleID == "design-lint.unverified-uncovered" })
  }

  @Test(
    "five [UNVERIFIED] bullets plus one unrelated Risks bullet gives five findings — catches the coverage check being satisfied by unrelated content in the section"
  )
  func fiveUnverifiedBulletsWithOneUnrelatedRiskGivesFiveFindings() throws {
    let text = """
      ## Evidence

      - [UNVERIFIED] claim one is unverified
      - [UNVERIFIED] claim two is unverified
      - [UNVERIFIED] claim three is unverified
      - [UNVERIFIED] claim four is unverified
      - [UNVERIFIED] claim five is unverified

      ## Risks

      - Some unrelated risk about something else entirely.
      """
    let findings = try Self.check(Self.parse(text))
    #expect(findings.filter { $0.ruleID == "design-lint.unverified-uncovered" }.count == 5)
  }

  @Test("an [UNVERIFIED] bullet exactly restated in Risks is not flagged")
  func unverifiedExactlyRestatedInRisksIsNotFlagged() throws {
    let text = """
      ## Evidence

      - [UNVERIFIED] the underlying claim text

      ## Risks

      - the underlying claim text
      """
    let findings = try Self.check(Self.parse(text))
    #expect(findings.filter { $0.ruleID == "design-lint.unverified-uncovered" } == [])
  }

  @Test(
    "a bullet ending \"[UNVERIFIED].\" matches its Risks restatement — catches the space left before the period defeating the match"
  )
  func trailingUnverifiedTagBeforePeriodMatchesRisks() throws {
    let text = """
      ## Evidence

      - The review guidelines allow silent background submission [UNVERIFIED].

      ## Risks

      - The review guidelines allow silent background submission.
      """
    let findings = try Self.check(Self.parse(text))
    #expect(findings.filter { $0.ruleID == "design-lint.unverified-uncovered" } == [])
  }

  // MARK: - Duplicate claim ids

  @Test(
    "a claim id repeated in claims.jsonl is a gating finding and a Decision citing it is flagged whichever copy comes last — catches a later 'supported' line hiding a refuted one",
    arguments: [
      [Claim.Status.refuted, .supported], [Claim.Status.supported, .refuted],
    ])
  func duplicateClaimIdPicksNoWinner(order: [Claim.Status]) throws {
    let text = """
      ## Decision

      - Use the queue-backed approach [ev-twice-recorded]
      """
    let claims = order.map { Self.claim(id: "ev-twice-recorded", status: $0) }
    let findings = try Self.check(Self.parse(text), claims: claims)
    let duplicate = try #require(findings.first { $0.ruleID == "design-lint.claim-id-duplicate" })
    #expect(duplicate.severity.failsGate)
    #expect(duplicate.message.contains("ev-twice-recorded"))
    #expect(findings.contains { $0.ruleID == "design-lint.citation-not-supported" })

    let distinct = try Self.check(
      Self.parse(text),
      claims: order.enumerated().map {
        Self.claim(id: "ev-recorded-\($0.offset)", status: $0.element)
      })
    #expect(!distinct.contains { $0.ruleID == "design-lint.claim-id-duplicate" })
  }

  @Test(
    "an [UNVERIFIED] bullet restated with extra context around it in Open questions is not flagged"
  )
  func unverifiedRestatedWithExtraContextIsNotFlagged() throws {
    let text = """
      ## Evidence

      - [UNVERIFIED] the underlying claim text

      ## Open questions

      - There's uncertainty here: the underlying claim text — needs confirmation before ship.
      """
    let findings = try Self.check(Self.parse(text))
    #expect(findings.filter { $0.ruleID == "design-lint.unverified-uncovered" } == [])
  }

  @Test(
    "an [UNVERIFIED] bullet restated with different case and whitespace in Risks is not flagged")
  func unverifiedRestatedWithDifferentCaseAndWhitespaceIsNotFlagged() throws {
    let text = """
      ## Evidence

      - [UNVERIFIED] The Underlying   Claim Text

      ## Risks

      - the underlying claim text
      """
    let findings = try Self.check(Self.parse(text))
    #expect(findings.filter { $0.ruleID == "design-lint.unverified-uncovered" } == [])
  }

  @Test(
    "an [UNVERIFIED] bullet only paraphrased (not restated) in Risks is still flagged — catches a mechanical check accepting a summary it can't actually verify"
  )
  func unverifiedParaphrasedNotRestatedIsFlagged() throws {
    let text = """
      ## Evidence

      - [UNVERIFIED] the underlying claim text

      ## Risks

      - a completely different description with no shared wording
      """
    let findings = try Self.check(Self.parse(text))
    #expect(findings.contains { $0.ruleID == "design-lint.unverified-uncovered" })
  }

  @Test("an [UNVERIFIED] bullet restated in both Risks and Open questions is not flagged")
  func unverifiedInBothRisksAndOpenQuestionsIsNotFlagged() throws {
    let text = """
      ## Decision

      - Use the queue-backed approach [UNVERIFIED]

      ## Risks

      - [UNVERIFIED] Use the queue-backed approach — risk noted.

      ## Open questions

      - [UNVERIFIED] Use the queue-backed approach — question noted.
      """
    let findings = try Self.check(Self.parse(text))
    #expect(findings.filter { $0.ruleID == "design-lint.unverified-uncovered" } == [])
  }

  // MARK: - [UNVERIFIED] is forbidden in Decision (spec §11: refuted or [UNVERIFIED], never in Decision)

  @Test(
    "an [UNVERIFIED]-tagged Decision bullet is flagged, not accepted as merely tagged — catches an unverified claim backing a decision"
  )
  func unverifiedDecisionBulletIsFlagged() throws {
    let text = """
      ## Decision

      - Use the queue-backed approach [UNVERIFIED]
      """
    let findings = try Self.check(Self.parse(text))
    #expect(findings.contains { $0.ruleID == "design-lint.unverified-in-decision" })
    // Carrying the [UNVERIFIED] tag must not be read as satisfying "each tagged."
    #expect(findings.contains { $0.ruleID == "design-lint.untagged-bullet" } == false)
  }

  @Test("a Decision bullet tagged with a supported claim and no [UNVERIFIED] is not flagged")
  func decisionBulletWithoutUnverifiedIsNotFlagged() throws {
    let text = """
      ## Decision

      - Use the queue-backed approach [ev-good-claim]
      """
    let findings = try Self.check(
      Self.parse(text), claims: [Self.claim(id: "ev-good-claim", status: .supported)])
    #expect(findings.filter { $0.ruleID == "design-lint.unverified-in-decision" } == [])
  }

  // MARK: - Perf & scale's seven dimensions

  @Test(
    "Perf & scale missing exactly one dimension is flagged for that dimension only — catches an incomplete perf review passing",
    arguments: DesignLintEvidence.PerfDimension.allCases)
  func perfMissingOneDimensionIsFlagged(missing: DesignLintEvidence.PerfDimension) throws {
    let allBullets: [DesignLintEvidence.PerfDimension: String] = [
      .throughput: "- throughput: 100 req/s per instance [\(Self.supportedClaimID)]",
      .tailLatency: "- tail latency: p99 under 200ms [\(Self.supportedClaimID)]",
      .fanOut: "- fan-out: one worker per shard [\(Self.supportedClaimID)]",
      .failureIsolation:
        "- failure isolation: one shard failing doesn't affect others [\(Self.supportedClaimID)]",
      .resources: "- resources: bounded to 4 workers per host [\(Self.supportedClaimID)]",
      .backpressure: "- backpressure: queue rejects once full [\(Self.supportedClaimID)]",
      .tenX: "- 10×: still within budget at 10x load [\(Self.supportedClaimID)]",
    ]
    let perf = allBullets.filter { $0.key != missing }.values.joined(separator: "\n")
    let findings = try Self.check(
      Self.parse(Self.wellFormedDoc(perfOverride: perf)), claims: Self.wellFormedClaims)
    let perfFindings = findings.filter { $0.ruleID == "design-lint.perf-missing-dimension" }
    #expect(perfFindings.count == 1)
    #expect(perfFindings.first?.message.contains(missing.displayName) == true)
  }

  @Test("Perf & scale naming all seven dimensions has no missing-dimension findings")
  func perfNamingAllSevenIsNotFlagged() throws {
    let findings = try Self.check(Self.parse(Self.wellFormedDoc()), claims: Self.wellFormedClaims)
    #expect(findings.filter { $0.ruleID == "design-lint.perf-missing-dimension" } == [])
  }

  @Test("a missing Perf & scale section is flagged for all seven dimensions")
  func missingPerfSectionFlagsAllSevenDimensions() throws {
    let findings = try Self.check(Self.parse("## Problem\n\nSome text."))
    let perfFindings = findings.filter { $0.ruleID == "design-lint.perf-missing-dimension" }
    #expect(perfFindings.count == DesignLintEvidence.PerfDimension.allCases.count)
  }

  // MARK: - False positives

  @Test(
    "a tag-like token inside a fenced code block is not treated as a citation — catches a code sample being misread as an untagged or unknown citation"
  )
  func tagLikeTokenInsideCodeFenceIsNotFlagged() throws {
    let text = """
      ## Decision

      - Use the queue-backed approach [\(Self.supportedClaimID)]

      ```swift
      // example only: [ev-not-a-real-citation]
      let x = 1
      ```
      """
    let findings = try Self.check(Self.parse(text), claims: Self.wellFormedClaims)
    #expect(
      findings.filter {
        $0.ruleID == "design-lint.untagged-bullet" || $0.ruleID == "design-lint.unknown-claim"
      } == [])
  }

  @Test(
    "a tag-like token inside inline code is not treated as a citation — catches example syntax being misread as an untagged or unknown citation"
  )
  func tagLikeTokenInsideInlineCodeIsNotFlagged() throws {
    let text = """
      ## Decision

      - Use `[ev-example-syntax]` as the citation format [\(Self.supportedClaimID)]
      """
    let findings = try Self.check(Self.parse(text), claims: Self.wellFormedClaims)
    #expect(
      findings.filter {
        $0.ruleID == "design-lint.untagged-bullet" || $0.ruleID == "design-lint.unknown-claim"
      } == [])
  }

  @Test(
    "a Decision bullet that wraps onto a continuation line with its tag on the first line is not flagged untagged"
  )
  func decisionBulletWrappingWithTagOnFirstLineIsNotFlagged() throws {
    let text = """
      ## Decision

      - Use the queue-backed approach [\(Self.supportedClaimID)]
        because it keeps retry logic on the client and avoids a server migration.
      """
    let findings = try Self.check(Self.parse(text), claims: Self.wellFormedClaims)
    #expect(findings.filter { $0.ruleID == "design-lint.untagged-bullet" } == [])
  }

  // MARK: - Shared valid design doc fixture (used across sibling design-lint suites)

  @Test("the repo's valid design doc fixture has no evidence-tag findings")
  func repoValidDesignFixtureHasNoFindings() throws {
    let findings = try Self.check(
      try Self.fixture("valid.md"),
      claims: [Self.claim(id: "ev-tca-effect-run-supports-cancellation", status: .supported)])
    #expect(findings == [])
  }

  @Test("the repo's valid design doc fixture still has no diagram/budget findings")
  func repoValidDesignFixtureHasNoDiagramFindings() throws {
    let document = try Self.fixture("valid.md")
    let findings = try DesignLintDiagrams.check(
      document: document, docPath: "docs/example/designs/x.md", budgets: DocsBudgets())
    #expect(findings == [])
  }

  // MARK: - Findings carry rule ids and a locatable file

  @Test("every finding names its rule id and the design doc's path")
  func findingsCarryRuleIDAndPath() throws {
    let text = """
      ## Decision

      - Use the queue-backed approach [UNVERIFIED]
      """
    let findings = try Self.check(Self.parse(text))
    #expect(!findings.isEmpty)
    for finding in findings {
      #expect(!finding.ruleID.isEmpty)
      #expect(finding.file == "docs/example/designs/x.md")
    }
  }
}

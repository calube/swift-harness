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
      ## Decision

      - Use the queue-backed approach [UNVERIFIED]
      """
    let findings = try Self.check(Self.parse(text))
    #expect(findings.contains { $0.ruleID == "design-lint.unverified-uncovered" })
  }

  @Test("an [UNVERIFIED] bullet is not flagged once Risks has any content")
  func unverifiedCoveredByRisksIsNotFlagged() throws {
    let text = """
      ## Decision

      - Use the queue-backed approach [UNVERIFIED]

      ## Risks

      - Something worth tracking, unrelated wording is fine.
      """
    let findings = try Self.check(Self.parse(text))
    #expect(findings.filter { $0.ruleID == "design-lint.unverified-uncovered" } == [])
  }

  @Test("an [UNVERIFIED] bullet is not flagged once Open questions has any content")
  func unverifiedCoveredByOpenQuestionsIsNotFlagged() throws {
    let text = """
      ## Decision

      - Use the queue-backed approach [UNVERIFIED]

      ## Open questions

      - Something worth tracking, unrelated wording is fine.
      """
    let findings = try Self.check(Self.parse(text))
    #expect(findings.filter { $0.ruleID == "design-lint.unverified-uncovered" } == [])
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

  @Test("[UNVERIFIED] appearing in both Risks and Open questions is not flagged")
  func unverifiedInBothRisksAndOpenQuestionsIsNotFlagged() throws {
    let text = """
      ## Decision

      - Use the queue-backed approach [UNVERIFIED]

      ## Risks

      - [UNVERIFIED] Some risk worth tracking.

      ## Open questions

      - [UNVERIFIED] Some open question worth tracking.
      """
    let findings = try Self.check(Self.parse(text))
    #expect(findings.filter { $0.ruleID == "design-lint.unverified-uncovered" } == [])
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

import Foundation
import Testing

@testable import SwiftGateDomain

@Suite("review-synth --design: design review verdict (spec §8.2)")
struct DesignReviewVerdictTests {
  static let doc = MarkdownDocument.parse(
    """
    ---
    status: proposed
    area: menu
    tier: standard
    ---

    # Cache the menu per brand

    ## Problem

    Menu loads are slow.

    ## Decision

    - Cache the menu per brand [ev-menu-cache-hit-rate]

    ### Rollback

    Flip the cache flag off.

    ## Perf & scale

    - throughput: 40 loads per second [ev-menu-cache-hit-rate]

    ## Risks

    - A stale menu after an edit.

    ```markdown
    ## Fenced heading
    ```
    """)

  static func finding(
    _ severity: Severity, anchor: String = "perf--scale", category: String = "unsupported-claim",
    verified: Bool? = true, scenario: String? = "a brand with 10k items blows the cache budget",
    kind: ReviewFinding.Kind? = nil, rule: String? = nil
  ) -> DesignFinding {
    DesignFinding(
      anchor: anchor, severity: severity, category: category, title: "throughput is unsupported",
      failureScenario: scenario, evidence: "ev-menu-cache-hit-rate measures hit rate, not load",
      fix: "cite a load measurement", verified: verified, kind: kind, rule: rule)
  }

  static func reviewed(_ reviewer: DesignReviewer, _ findings: [DesignFinding] = []) -> DesignReview
  {
    DesignReview(reviewer: reviewer, status: .reviewed, reason: nil, findings: findings)
  }

  static func synthesize(_ inputs: [DesignReview], tier: DesignTier)
    throws(DesignReviewContractViolation) -> DesignReviewReport
  {
    try DesignReviewSynthesis.synthesize(inputs, tier: tier, document: doc)
  }

  // MARK: - Required reviewer sets

  @Test(
    "each tier requires exactly its reviewer set — catches deep dropping the pre-mortem or quick demanding reviewers"
  )
  func requiredSets() {
    #expect(DesignTier.quick.requiredReviewers == [])
    #expect(
      DesignTier.standard.requiredReviewers == [.evidenceAuditor, .standardsReviewer, .challenger])
    #expect(
      DesignTier.deep.requiredReviewers == [
        .evidenceAuditor, .standardsReviewer, .challenger, .preMortem,
      ])
  }

  // MARK: - Fail-closed property

  /// Every state a required reviewer can be in. Only `clean` and `minorOnly` may yield `ready`.
  enum ReviewerState: CaseIterable {
    case clean, minorOnly, major, blocker, missing, notReviewed, notResearched

    var allowsReady: Bool { self == .clean || self == .minorOnly }

    func review(for reviewer: DesignReviewer) -> DesignReview? {
      switch self {
      case .clean: DesignReviewVerdictTests.reviewed(reviewer)
      case .minorOnly: DesignReviewVerdictTests.reviewed(reviewer, [finding(.minor)])
      case .major: DesignReviewVerdictTests.reviewed(reviewer, [finding(.major)])
      case .blocker: DesignReviewVerdictTests.reviewed(reviewer, [finding(.blocker)])
      case .missing: nil
      case .notReviewed:
        DesignReview(reviewer: reviewer, status: .notReviewed, reason: "agent died", findings: [])
      case .notResearched:
        DesignReview(
          reviewer: reviewer, status: .notResearched, reason: "perf lane returned nothing",
          findings: [])
      }
    }
  }

  static func combinations(count: Int) -> [[ReviewerState]] {
    (0..<count).reduce([[]]) { partial, _ in
      partial.flatMap { prefix in ReviewerState.allCases.map { prefix + [$0] } }
    }
  }

  @Test(
    "ready only when every required reviewer is present with no blocker or major, over every state combination — catches a dead, missing or unresearched reviewer passing",
    arguments: DesignTier.allCases)
  func failClosed(tier: DesignTier) throws {
    let required = tier.requiredReviewers
    let combinations = Self.combinations(count: required.count)
    #expect(
      combinations.count == Int(pow(Double(ReviewerState.allCases.count), Double(required.count))))
    for states in combinations {
      let inputs = zip(required, states).compactMap { reviewer, state in state.review(for: reviewer)
      }
      let report = try Self.synthesize(inputs, tier: tier)
      let expectReady = states.allSatisfy(\.allowsReady)
      #expect(
        (report.verdict == .ready) == expectReady,
        "tier \(tier) states \(states) → \(report.verdict)")
      if !expectReady {
        #expect(report.verdict == .revise, "tier \(tier) states \(states)")
        let failing = zip(required, states).filter { !$0.1.allowsReady }.map(\.0)
        #expect(report.rerun == failing, "tier \(tier) states \(states)")
      } else {
        #expect(report.rerun.isEmpty)
      }
    }
  }

  // MARK: - quick

  @Test(
    "quick with no reviewer files is ready: no reviewer gate applies — catches quick demanding agents it never runs"
  )
  func quickWithoutReviewersIsReady() throws {
    let report = try Self.synthesize([], tier: .quick)
    #expect(report.verdict == .ready)
    #expect(report.required.isEmpty)
    #expect(report.rerun.isEmpty)
  }

  @Test(
    "quick still fails closed on any reviewer file it is given — catches an optional reviewer's major or death being ignored"
  )
  func quickSuppliedReviewersStillCount() throws {
    let major = try Self.synthesize(
      [Self.reviewed(.challenger, [Self.finding(.major)])], tier: .quick)
    #expect(major.verdict == .revise)
    #expect(major.rerun == [.challenger])

    let dead = try Self.synthesize(
      [DesignReview(reviewer: .challenger, status: .notReviewed, reason: "timeout", findings: [])],
      tier: .quick)
    #expect(dead.verdict == .revise)
    #expect(dead.notReviewed.map(\.reviewer) == [.challenger])

    let unresearched = try Self.synthesize(
      [
        DesignReview(
          reviewer: .evidenceAuditor, status: .notResearched, reason: "lane died", findings: [])
      ], tier: .quick)
    #expect(unresearched.verdict == .revise)
    #expect(unresearched.notResearched.map(\.reviewer) == [.evidenceAuditor])
  }

  // MARK: - Plan-named behaviours

  @Test("deep without the pre-mortem is NOT REVIEWED, not ready — catches a skipped reviewer")
  func deepWithoutPreMortem() throws {
    let report = try Self.synthesize(
      [
        Self.reviewed(.evidenceAuditor), Self.reviewed(.standardsReviewer),
        Self.reviewed(.challenger),
      ],
      tier: .deep)
    #expect(report.verdict == .revise)
    #expect(report.notReviewed.map(\.reviewer) == [.preMortem])
    #expect(report.rerun == [.preMortem])
  }

  @Test(
    "a blocker on the Decision, or a subsection of it, is rethink — catches a refuted decision getting a redraft"
  )
  func decisionBlockerIsRethink() throws {
    for anchor in ["decision", "rollback"] {
      let report = try Self.synthesize(
        [
          Self.reviewed(.evidenceAuditor, [Self.finding(.blocker, anchor: anchor)]),
          Self.reviewed(.standardsReviewer), Self.reviewed(.challenger),
        ], tier: .standard)
      #expect(report.verdict == .rethink, "anchor \(anchor)")
      #expect(report.rerun == [.evidenceAuditor])
    }
  }

  @Test(
    "a major on the Decision, or a blocker elsewhere, is revise — catches rethink firing on anything but a Decision blocker"
  )
  func onlyDecisionBlockerIsRethink() throws {
    let majorOnDecision = try Self.synthesize(
      [
        Self.reviewed(.evidenceAuditor, [Self.finding(.major, anchor: "decision")]),
        Self.reviewed(.standardsReviewer), Self.reviewed(.challenger),
      ], tier: .standard)
    #expect(majorOnDecision.verdict == .revise)

    let blockerOnRisks = try Self.synthesize(
      [
        Self.reviewed(.evidenceAuditor), Self.reviewed(.standardsReviewer),
        Self.reviewed(.challenger, [Self.finding(.blocker, anchor: "risks")]),
      ], tier: .standard)
    #expect(blockerOnRisks.verdict == .revise)
  }

  @Test(
    "a major elsewhere is revise naming only the reviewer that raised it — catches clean reviewers being re-run"
  )
  func reviseNamesOnlyTheDrivingReviewer() throws {
    let report = try Self.synthesize(
      [
        Self.reviewed(.evidenceAuditor, [Self.finding(.minor, anchor: "problem")]),
        Self.reviewed(.standardsReviewer, [Self.finding(.major, anchor: "risks")]),
        Self.reviewed(.challenger),
      ], tier: .standard)
    #expect(report.verdict == .revise)
    #expect(report.rerun == [.standardsReviewer])
  }

  @Test(
    "a reviewer that rated a shared finding minor is not re-run when another rated it major — catches the merge widening the re-run set"
  )
  func sharedFindingRerunsOnlyTheGatingReviewer() throws {
    let report = try Self.synthesize(
      [
        Self.reviewed(.evidenceAuditor, [Self.finding(.minor)]),
        Self.reviewed(.standardsReviewer, [Self.finding(.major)]),
        Self.reviewed(.challenger),
      ], tier: .standard)
    #expect(report.findings.first?.reviewers == [.evidenceAuditor, .standardsReviewer])
    #expect(report.verdict == .revise)
    #expect(report.rerun == [.standardsReviewer])
  }

  // MARK: - Anchors

  @Test(
    "an anchor absent from the doc is a contract violation, including a case-only match and a heading inside a code fence — catches a finding pinned to nothing"
  )
  func absentAnchorIsContractViolation() {
    for anchor in ["no-such-section", "Decision", "fenced-heading", ""] {
      #expect(
        throws: DesignReviewContractViolation.unknownAnchor(reviewer: .challenger, anchor: anchor),
        "anchor \(anchor)"
      ) {
        try Self.synthesize(
          [Self.reviewed(.challenger, [Self.finding(.nit, anchor: anchor)])], tier: .quick)
      }
    }
  }

  @Test(
    "an absent anchor is a violation even on a finding verify would drop — catches a malformed reviewer output hiding behind the drop step"
  )
  func absentAnchorOnDroppedFinding() {
    #expect(
      throws: DesignReviewContractViolation.unknownAnchor(reviewer: .challenger, anchor: "gone")
    ) {
      try Self.synthesize(
        [Self.reviewed(.challenger, [Self.finding(.blocker, anchor: "gone", verified: false)])],
        tier: .quick)
    }
  }

  // MARK: - Contract on inputs

  @Test(
    "a duplicate reviewer is a contract violation — catches a second file overwriting a blocker")
  func duplicateReviewer() {
    #expect(throws: DesignReviewContractViolation.duplicateReviewer(.challenger)) {
      try Self.synthesize(
        [Self.reviewed(.challenger, [Self.finding(.major)]), Self.reviewed(.challenger)],
        tier: .standard)
    }
  }

  static func envelope(
    reviewer: String = "challenger", status: String = "reviewed", schemaVersion: Int = 1,
    finding: String? = nil
  ) -> Data {
    let findings = finding.map { "[\($0)]" } ?? "[]"
    return Data(
      """
      {"schemaVersion": \(schemaVersion), "reviewer": "\(reviewer)", "status": "\(status)",
       "findings": \(findings)}
      """.utf8)
  }

  static let wireFinding = """
    {"severity": "major", "category": "blind-spot", "location": {"anchor": "risks"},
     "title": "no rollback drill", "failure_scenario": "a bad cache ships with no tested rollback",
     "evidence": "Risks names no drill", "fix": "add a drill", "verified": true}
    """

  @Test(
    "a reviewer file decodes location.anchor into the Foundation finding fields — catches the design contract drifting from §9.1"
  )
  func decodesWireFinding() throws {
    let review = try DesignReviewJSON.decode(Self.envelope(finding: Self.wireFinding))
    #expect(review.reviewer == .challenger)
    #expect(review.status == .reviewed)
    let finding = try #require(review.findings.first)
    #expect(finding.anchor == "risks")
    #expect(finding.finding.severity == .major)
    #expect(finding.finding.failureScenario == "a bad cache ships with no tested rollback")
    #expect(try DesignReviewJSON.decode(DesignReviewJSON.encode(review)) == review)
  }

  @Test(
    "an unknown reviewer, unknown status, file:line location or other schema version is rejected — catches an unrecognised input being ignored"
  )
  func rejectsOffContractFiles() {
    #expect(throws: DecodingError.self) {
      try DesignReviewJSON.decode(Self.envelope(reviewer: "architecture"))
    }
    #expect(throws: DecodingError.self) {
      try DesignReviewJSON.decode(Self.envelope(status: "not-applicable"))
    }
    let located = """
      {"severity": "major", "category": "x", "location": {"anchor": "risks"}, "file": "A.swift",
       "line": 3, "title": "t", "failure_scenario": "s", "evidence": "e", "fix": "f",
       "verified": true}
      """
    #expect(throws: DecodingError.self) {
      try DesignReviewJSON.decode(Self.envelope(finding: located))
    }
    let unlocated = """
      {"severity": "major", "category": "x", "title": "t", "failure_scenario": "s",
       "evidence": "e", "fix": "f", "verified": true}
      """
    #expect(throws: DecodingError.self) {
      try DesignReviewJSON.decode(Self.envelope(finding: unlocated))
    }
    #expect(throws: DesignReviewContractViolation.unsupportedSchemaVersion(2)) {
      try DesignReviewJSON.decode(Self.envelope(schemaVersion: 2))
    }
  }

  // MARK: - Reused Foundation finding rules

  @Test(
    "code and design review drop the same finding for the same reason — catches the two verify steps drifting apart",
    arguments: [
      (scenario: String?.none, verified: Bool?.some(true), kind: ReviewFinding.Kind?.none),
      (scenario: "   ", verified: true, kind: nil),
      (scenario: "a load spike evicts the cache", verified: true, kind: .standardsViolation),
      (scenario: "a load spike evicts the cache", verified: false, kind: nil),
      (scenario: "a load spike evicts the cache", verified: nil, kind: nil),
      (scenario: "a load spike evicts the cache", verified: true, kind: nil),
    ])
  func codeAndDesignDropAlike(
    scenario: String?, verified: Bool?, kind: ReviewFinding.Kind?
  ) throws {
    let design = Self.finding(.major, verified: verified, scenario: scenario, kind: kind)
    let code = ReviewFinding(
      severity: .major, category: design.finding.category, file: "Sources/Core/A.swift", line: 4,
      title: design.finding.title, failureScenario: scenario, evidence: design.finding.evidence,
      fix: design.finding.fix, verified: verified, kind: kind, rule: nil)

    let codeReport = try ReviewSynthesis.synthesize(
      ReviewFocus.allCases.map {
        FocusReview(
          focus: $0, status: .reviewed, reason: nil, findings: $0 == .architecture ? [code] : [])
      })
    let designReport = try Self.synthesize([Self.reviewed(.challenger, [design])], tier: .quick)

    #expect(codeReport.dropped.map(\.reason) == designReport.dropped.map(\.reason))
    #expect(codeReport.findings.count == designReport.findings.count)
    #expect(codeReport.dropped.count + codeReport.findings.count == 1)
  }

  @Test(
    "unverified, scenario-less and rule-less findings are dropped with their reasons — catches a dropped design blocker still gating"
  )
  func dropsLikeReviewSynth() throws {
    let report = try Self.synthesize(
      [
        Self.reviewed(
          .challenger,
          [
            Self.finding(.blocker, verified: false),
            Self.finding(.major, category: "other", scenario: "  "),
            Self.finding(.major, category: "third", kind: .standardsViolation, rule: nil),
          ])
      ], tier: .quick)
    #expect(report.verdict == .ready)
    #expect(
      report.dropped.map(\.reason).sorted { $0.rawValue < $1.rawValue } == [
        .noFailureScenario, .noRuleCitation, .unverified,
      ])
  }

  @Test(
    "two reviewers flagging one anchor and category merge into one finding naming both — catches double-counted findings"
  )
  func mergesAcrossReviewers() throws {
    let report = try Self.synthesize(
      [
        Self.reviewed(.evidenceAuditor, [Self.finding(.major)]),
        Self.reviewed(.challenger, [Self.finding(.blocker)]),
        Self.reviewed(.standardsReviewer),
      ], tier: .standard)
    #expect(report.findings.count == 1)
    #expect(report.findings.first?.reviewers == [.evidenceAuditor, .challenger])
    #expect(report.findings.first?.finding.finding.severity == .blocker)
    #expect(report.rerun == [.evidenceAuditor, .challenger])
  }

  @Test(
    "the summary leads with the verdict and the reviewers to re-run — catches a caller missing which agents to run again"
  )
  func summary() throws {
    let report = try Self.synthesize(
      [Self.reviewed(.evidenceAuditor), Self.reviewed(.challenger, [Self.finding(.major)])],
      tier: .standard)
    let text = DesignReviewSummary.render(report, reportPath: "run/design-review.json")
    let lines = text.split(separator: "\n").map(String.init)
    #expect(lines.first?.hasPrefix("design review: revise (tier standard)") == true)
    #expect(lines.contains("re-run: standards-reviewer, challenger"))
    #expect(
      lines.contains("NOT REVIEWED: standards-reviewer (no result was produced for this reviewer)"))
    #expect(lines.contains { $0.contains("[major] challenger/unsupported-claim #perf--scale") })
  }
}

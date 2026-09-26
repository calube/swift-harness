import Foundation
import SwiftGateDomain
import Testing

@Suite("Design and plan metrics")
struct DesignMetricsTests {
  private static func claim(
    id: String, lane: String, status: Claim.Status, kind: Citation.Kind = .file
  ) -> Claim {
    Claim(
      id: id, lane: lane, text: "some fact",
      citation: Citation(kind: kind, loc: "some/path.swift:L1-L2", pin: nil, quote: "x"),
      status: status)
  }

  private static func amendment(class amendmentClass: Amendment.Class, changedIds: [String])
    -> Amendment
  {
    Amendment(
      title: "a change", at: Date(timeIntervalSince1970: 0), class: amendmentClass,
      fromSha: "aaa", toSha: "bbb", changedIds: changedIds, newClaims: [],
      trigger: "design-conflict", review: nil, approval: nil)
  }

  // MARK: - Rate

  @Test("a rate with a zero denominator is nil — catches a fabricated 0% or 100%")
  func rateNilOnZeroDenominator() {
    #expect(Rate(numerator: 0, denominator: 0).value == nil)
    #expect(Rate(numerator: 3, denominator: 4).value == 0.75)
  }

  // MARK: - Escape rate

  @Test("a supported claim named by a later amend amendment counts as escaped")
  func escapeRateCountsAmendedSupportedClaim() {
    let claims = [Self.claim(id: "ev-cancel-effect-works", lane: "packages", status: .supported)]
    let amendments = [Self.amendment(class: .amend, changedIds: ["ev-cancel-effect-works"])]

    let report = DesignMetrics.escapeRate(claims: claims, amendments: amendments)

    #expect(report.escapedClaimIDs == ["ev-cancel-effect-works"])
    #expect(report.supportedCount == 1)
    #expect(report.rate.value == 1.0)
  }

  @Test(
    "a supported claim untouched by any amendment, or named only by a clarify, doesn't count as escaped"
  )
  func escapeRateExcludesUnamendedAndClarifyOnlyClaims() {
    let claims = [
      Self.claim(id: "ev-cancel-effect-works", lane: "packages", status: .supported),
      Self.claim(id: "ev-retry-backoff-caps-at-30s", lane: "codebase", status: .supported),
    ]
    let amendments = [
      Self.amendment(class: .clarify, changedIds: ["ev-cancel-effect-works"])
    ]

    let report = DesignMetrics.escapeRate(claims: claims, amendments: amendments)

    #expect(report.escapedClaimIDs.isEmpty)
    #expect(report.supportedCount == 2)
    #expect(report.rate.value == 0.0)
  }

  @Test("escape rate is n/a when nothing is supported yet")
  func escapeRateNilWhenNoSupportedClaims() {
    let report = DesignMetrics.escapeRate(claims: [], amendments: [])
    #expect(report.rate.value == nil)
  }

  // MARK: - Lane metrics

  @Test("refute and UNVERIFIED rate are computed per lane, over a closed lane set")
  func laneReportBucketsRefutedAndUnverified() {
    let claims = [
      Self.claim(id: "ev-a-b-c", lane: "packages", status: .supported),
      Self.claim(id: "ev-d-e-f", lane: "packages", status: .refuted),
      Self.claim(id: "ev-g-h-i", lane: "packages", status: .new),
      Self.claim(id: "ev-j-k-l", lane: "codebase", status: .quoteFail),
    ]

    let report = DesignMetrics.laneReport(claims)

    let packages = report.lanes.first { $0.lane == .packages }
    #expect(packages?.total == 3)
    // refuted and UNVERIFIED are disjoint badges (spec §12): 1 refuted, 1 still new (UNVERIFIED),
    // 1 supported.
    #expect(packages?.refuteRate.value == 1.0 / 3.0)
    #expect(packages?.unverifiedRate.value == 1.0 / 3.0)

    let codebase = report.lanes.first { $0.lane == .codebase }
    #expect(codebase?.total == 1)
    #expect(codebase?.unverifiedRate.value == 1.0)
    #expect(codebase?.refuteRate.value == 0.0)

    // Every known lane is present even with no claims, and its rate is n/a, not 0%.
    let appleDocs = report.lanes.first { $0.lane == .appleDocs }
    #expect(appleDocs?.total == 0)
    #expect(appleDocs?.refuteRate.value == nil)
  }

  @Test("a claim naming an unrecognised lane is counted apart and named, never merged silently")
  func laneReportNamesUnknownLane() {
    let claims = [Self.claim(id: "ev-a-b-c", lane: "vibes", status: .supported)]

    let report = DesignMetrics.laneReport(claims)

    #expect(report.unknownLaneClaimCounts == ["vibes": 1])
    #expect(report.lanes.allSatisfy { $0.total == 0 })
  }

  // MARK: - review-log.jsonl / reviewer precision

  @Test("review-log.jsonl round-trips byte-stable — catches schema drift")
  func reviewLogRoundTrips() throws {
    let record = ReviewLogRecord(
      findingId: "finding-decision-contradicts-evidence", reviewer: "evidence-auditor",
      disposition: .accepted, reason: "the cited quote doesn't support the decision")
    let firstPass = try ReviewLogJSON.encodeLine(record)
    let decoded = try StrictJSONL.decode(
      ReviewLogRecord.self, data: firstPass, path: "review-log.jsonl")
    #expect(decoded == [record])
    let secondPass = try ReviewLogJSON.encodeLine(decoded[0])
    #expect(firstPass == secondPass)
  }

  @Test(
    "reviewer precision is accepted / (accepted + dismissed) from Request-changes and dismissals")
  func reviewerPrecisionFromDispositions() {
    let records = [
      ReviewLogRecord(
        findingId: "f1", reviewer: "evidence-auditor", disposition: .accepted, reason: "r1"),
      ReviewLogRecord(
        findingId: "f2", reviewer: "evidence-auditor", disposition: .accepted, reason: "r2"),
      ReviewLogRecord(
        findingId: "f3", reviewer: "evidence-auditor", disposition: .dismissed, reason: "r3"),
      ReviewLogRecord(
        findingId: "f4", reviewer: "challenger", disposition: .dismissed, reason: "r4"),
    ]

    let precision = DesignMetrics.reviewerPrecision(records)

    let auditor = precision.first { $0.reviewer == "evidence-auditor" }
    #expect(auditor?.accepted == 2)
    #expect(auditor?.dismissed == 1)
    #expect(auditor?.precision.value == 2.0 / 3.0)

    let challenger = precision.first { $0.reviewer == "challenger" }
    #expect(challenger?.precision.value == 0.0)
  }

  @Test("a reviewer with no dispositions yet has n/a precision")
  func reviewerPrecisionNilWithNoDispositions() {
    #expect(DesignMetrics.reviewerPrecision([]).isEmpty)
  }

  // MARK: - phases.jsonl

  @Test("phases.jsonl round-trips byte-stable — catches schema drift")
  func phaseRecordRoundTrips() throws {
    let record = PhaseRecord(
      runId: "design-offline-order-queue", phase: .research, agentRole: .researchLane,
      lane: .packages, tokens: 12_000, costUSD: 0.42, wallMilliseconds: 90_000)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var firstPass = try encoder.encode(record)
    firstPass.append(UInt8(ascii: "\n"))
    let decoded = try StrictJSONL.decode(PhaseRecord.self, data: firstPass, path: "phases.jsonl")
    #expect(decoded == [record])
  }

  @Test("tokens, cost and wall time are totalled per phase and per agent role")
  func phaseAndAgentTotals() {
    let records = [
      PhaseRecord(
        runId: "design-x", phase: .research, agentRole: .researchLane, lane: .codebase,
        tokens: 1_000, costUSD: 0.10, wallMilliseconds: 5_000),
      PhaseRecord(
        runId: "design-x", phase: .research, agentRole: .researchLane, lane: .packages,
        tokens: 2_000, costUSD: 0.20, wallMilliseconds: 7_000),
      PhaseRecord(
        runId: "design-x", phase: .draft, agentRole: .drafter, tokens: 3_000, costUSD: nil,
        wallMilliseconds: 20_000),
    ]

    let byPhase = DesignMetrics.totalsByPhase(records)
    let research = byPhase.first { $0.key == .research }
    #expect(research?.runs == 2)
    #expect(research?.tokens == 3_000)
    #expect(abs((research?.costUSD ?? 0) - 0.30) < 0.0001)
    #expect(research?.wallMilliseconds == 12_000)
    // A phase with no records at all is omitted, not reported as a fabricated zero.
    #expect(!byPhase.contains { $0.key == .amend })

    let byAgent = DesignMetrics.totalsByAgent(records)
    let drafter = byAgent.first { $0.key == .drafter }
    #expect(drafter?.tokens == 3_000)
    // No contributing record carried a cost, so the total is nil, not 0.
    #expect(drafter?.costUSD == nil)

    let researchLane = byAgent.first { $0.key == .researchLane }
    #expect(researchLane?.runs == 2)
    #expect(researchLane?.tokens == 3_000)
  }

  @Test("overhead share is the wall-time fraction spent outside draft")
  func overheadShareExcludesDraft() {
    let records = [
      PhaseRecord(
        runId: "design-x", phase: .research, agentRole: .researchLane, tokens: 0, costUSD: nil,
        wallMilliseconds: 30_000),
      PhaseRecord(
        runId: "design-x", phase: .draft, agentRole: .drafter, tokens: 0, costUSD: nil,
        wallMilliseconds: 70_000),
    ]

    #expect(DesignMetrics.overheadShare(records).value == 0.3)
    #expect(DesignMetrics.overheadShare([]).value == nil)
  }

  // MARK: - Estimate error

  @Test("estimate error is computed only for tasks carrying actualLines; the rest are excluded")
  func estimateErrorExcludesTasksWithoutActuals() {
    let tasks = [
      TaskEstimate(id: "offline-queue-core-reducer", estLines: 200, actualLines: 260),
      TaskEstimate(id: "offline-queue-networking", estLines: 150, actualLines: nil),
    ]

    let report = DesignMetrics.estimateError(tasks)

    #expect(report.perTask.count == 1)
    #expect(report.perTask[0].error == 60)
    #expect(report.excludedTaskIDs == ["offline-queue-networking"])
    #expect(report.meanAbsoluteError == 60.0)
  }

  @Test("estimate error is nil when every task is excluded")
  func estimateErrorNilWhenAllExcluded() {
    let report = DesignMetrics.estimateError([
      TaskEstimate(id: "a-b-c", estLines: 100, actualLines: nil)
    ])
    #expect(report.meanAbsoluteError == nil)
    #expect(report.excludedTaskIDs == ["a-b-c"])
  }

  // MARK: - Probe fail rate

  private static func probeVerdict(claimId: String, verdict: ProbeVerdictRecord.Outcome)
    -> ProbeVerdictRecord
  {
    ProbeVerdictRecord(
      claimId: claimId, verdict: verdict, diagnostics: [], pins: [:], sdk: "iphonesimulator26.2")
  }

  @Test("probe fail rate is failed / total for one run's verdicts")
  func probeFailRateOverOneRun() {
    let verdicts = [
      Self.probeVerdict(claimId: "ev-a-b-c", verdict: .pass),
      Self.probeVerdict(claimId: "ev-d-e-f", verdict: .fail),
      Self.probeVerdict(claimId: "ev-g-h-i", verdict: .fail),
    ]

    let report = DesignMetrics.probeFailRate(verdicts)

    #expect(report.total == 3)
    #expect(report.failed == 2)
    #expect(report.failRate.value == 2.0 / 3.0)
  }

  @Test("probe fail rate is n/a when no probes ran this run")
  func probeFailRateNilWhenEmpty() {
    #expect(DesignMetrics.probeFailRate([]).failRate.value == nil)
  }

  // MARK: - Cache hit rate

  private static func reusableClaim(id: String, pin: String) throws -> ReusableClaim {
    let claim = Claim(
      id: id, lane: "packages", text: "fact",
      citation: Citation(
        kind: .file, loc: ".build/checkouts/swift-composable-architecture/x.swift:L1-L2",
        pin: pin, quote: "x"),
      status: .supported)
    return try ReusableClaim(claim)
  }

  @Test("cache hit rate is reuses / (reuses + entries) for one run's cache reads")
  func cacheHitRatePerRun() throws {
    let claims = [
      CachedClaim(
        claim: try Self.reusableClaim(
          id: "ev-a-b-c", pin: "swift-composable-architecture@1.26.2"),
        origin: .researchLane, reuseCount: 3),
      CachedClaim(
        claim: try Self.reusableClaim(
          id: "ev-d-e-f", pin: "swift-composable-architecture@1.26.2"),
        origin: .researchLane, reuseCount: 0),
    ]
    let verdicts = [
      CachedVerdict(verdict: .supported, origin: .claimChecker, reuseCount: 1)
    ]

    let report = DesignMetrics.cacheHitRate(claims: claims, verdicts: verdicts)

    #expect(report.entries == 3)
    #expect(report.reuses == 4)
    #expect(report.hitRate.value == 4.0 / 7.0)
  }

  @Test("cache hit rate is n/a when the cache has never been read for this run")
  func cacheHitRateNilWhenEmpty() {
    #expect(DesignMetrics.cacheHitRate(claims: [], verdicts: []).hitRate.value == nil)
  }

  // MARK: - Strict JSONL

  @Test("a malformed line names its file and 1-based line number rather than being dropped")
  func strictJSONLNamesMalformedLine() throws {
    var data = try ReviewLogJSON.encodeLine(
      ReviewLogRecord(findingId: "f1", reviewer: "r", disposition: .accepted, reason: "ok"))
    data.append(contentsOf: Array("{not json".utf8))
    data.append(UInt8(ascii: "\n"))

    #expect {
      try StrictJSONL.decode(ReviewLogRecord.self, data: data, path: "review-log.jsonl")
    } throws: { error in
      (error as? MalformedLine) == MalformedLine(path: "review-log.jsonl", line: 2)
    }
  }
}

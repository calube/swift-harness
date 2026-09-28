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

@Suite("Design workflow telemetry")
struct DesignWorkflowTelemetryTests {
  private static func line(_ json: String) -> Data { Data((json + "\n").utf8) }

  private static func decodeOne(_ json: String) throws -> PhaseRecord {
    let records = try StrictJSONL.decode(PhaseRecord.self, data: line(json), path: "phases.jsonl")
    return try #require(records.first)
  }

  private static func rejects(_ json: String) -> Bool {
    (try? StrictJSONL.decode(PhaseRecord.self, data: line(json), path: "phases.jsonl")) == nil
  }

  private static let schema2Base =
    #""runId":"design-20260928T010000Z","phase":"research","agentRole":"research-lane","lane":null,"costUSD":null,"wallMilliseconds":1200"#

  @Test(
    "a schema 2 line with unmeasured tokens encodes tokens as null next to its reason and reads back — catches a placeholder 0 standing in for an unknown count"
  )
  func unmeasuredSchemaTwoRoundTrips() throws {
    let record = PhaseRecord(
      runId: "design-20260928T010000Z", phase: .review, agentRole: nil, lane: nil, tokens: nil,
      costUSD: nil, wallMilliseconds: 61_000,
      unavailable: ["output tokens: the Workflow runtime gave this script no budget.spent()"])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let text = String(decoding: try encoder.encode(record), as: UTF8.self)
    #expect(text.contains(#""tokens":null"#))
    #expect(text.contains(#""schemaVersion":2"#))
    #expect(!text.contains(#""tokens":0"#))
    let decoded = try Self.decodeOne(text)
    #expect(decoded == record)
    #expect(decoded.tokens == nil)
  }

  @Test(
    "phase lines are closed and versioned: an unknown key, an unknown version, a schema 1 line without tokens, a schema 2 line without its tokens key or with null tokens and no reason all fail — catches a malformed record read as a real one"
  )
  func phaseLinesAreClosedAndVersioned() throws {
    let schema1 =
      #"{"schemaVersion":1,"runId":"design-20260925T180000Z","phase":"research","agentRole":"research-lane","lane":"codebase","tokens":48213,"costUSD":null,"wallMilliseconds":212000}"#
    #expect(try Self.decodeOne(schema1).tokens == 48_213)
    let schema2 = "{\"schemaVersion\":2,\(Self.schema2Base),\"tokens\":900,\"unavailable\":[]}"
    #expect(try Self.decodeOne(schema2).tokens == 900)

    #expect(Self.rejects(schema1.replacingOccurrences(of: #""tokens":48213,"#, with: "")))
    #expect(
      Self.rejects(schema1.replacingOccurrences(of: #""tokens":48213"#, with: #""tokens":null"#)))
    #expect(Self.rejects(schema1.replacingOccurrences(of: "{", with: #"{"model":"opus","#)))
    #expect(Self.rejects(schema1.replacingOccurrences(of: "}", with: #","unavailable":[]}"#)))
    #expect(
      Self.rejects(
        schema2.replacingOccurrences(of: #""schemaVersion":2"#, with: #""schemaVersion":3"#)))
    #expect(Self.rejects(schema2.replacingOccurrences(of: #""tokens":900,"#, with: "")))
    #expect(
      Self.rejects(schema2.replacingOccurrences(of: #""tokens":900"#, with: #""tokens":null"#)))
    #expect(Self.rejects(schema2.replacingOccurrences(of: #""tokens":900"#, with: #""tokens":-5"#)))
    #expect(Self.rejects(schema2.replacingOccurrences(of: #","unavailable":[]"#, with: "")))
  }

  @Test(
    "totals count unmeasured records apart and never add them as 0; a group with none measured has no token total — catches an unknown count summed as zero"
  )
  func totalsCountUnmeasuredApart() {
    let records = [
      PhaseRecord(
        runId: "design-x", phase: .research, agentRole: .researchLane, lane: .codebase,
        tokens: 1_000, costUSD: nil, wallMilliseconds: 5_000),
      PhaseRecord(
        runId: "design-x", phase: .research, agentRole: .researchLane, lane: nil, tokens: nil,
        costUSD: nil, wallMilliseconds: 9_000, unavailable: ["output tokens: no budget"]),
      PhaseRecord(
        runId: "design-x", phase: .review, agentRole: nil, lane: nil, tokens: nil,
        costUSD: nil, wallMilliseconds: 4_000, unavailable: ["output tokens: no budget"]),
    ]
    let byPhase = DesignMetrics.totalsByPhase(records)
    let research = byPhase.first { $0.key == .research }
    #expect(research?.runs == 2)
    #expect(research?.tokens == 1_000)
    #expect(research?.unmeasuredRuns == 1)
    #expect(research?.wallMilliseconds == 14_000)
    let review = byPhase.first { $0.key == .review }
    #expect(review?.runs == 1)
    #expect(review?.unmeasuredRuns == 1)
    #expect(review.map { $0.tokens == nil } == true)
    let lanes = DesignMetrics.totalsByAgent(records).first { $0.key == .researchLane }
    #expect(lanes?.unmeasuredRuns == 1)
    #expect(lanes?.tokens == 1_000)
  }

  private static let started = Date(timeIntervalSince1970: 1_790_000_000)
  private static let research = WorkflowTelemetry(
    outputTokens: 12_508,
    agents: [
      .init(label: "research:codebase", returned: true),
      .init(label: "research:packages", returned: false),
    ],
    unavailable: ["input tokens and USD cost: the Workflow script API reports neither"])

  @Test(
    "a workflow run becomes 1 schema 2 phase record with its tokens and its own wall time, and a telemetry record naming the transcript — catches whole-process time or a lost token count"
  )
  func makeBuildsBothRecords() throws {
    let made = try DesignTelemetry.make(
      runId: "design-20260928T010000Z", phase: .research, startedAt: Self.started,
      finishedAt: Self.started.addingTimeInterval(212.5), workflow: Self.research,
      session: .recorded(sessionId: "s-1", transcriptPath: "/tmp/t.jsonl"))
    #expect(made.phase.schemaVersion == 2)
    #expect(made.phase.tokens == 12_508)
    #expect(made.phase.wallMilliseconds == 212_500)
    #expect(made.phase.agentRole == .researchLane)
    #expect(made.phase.lane == nil)
    #expect(made.phase.costUSD == nil)
    #expect(made.phase.unavailable == Self.research.unavailable)
    #expect(made.telemetry.workflow == Self.research)
    #expect(made.telemetry.transcriptPath == "/tmp/t.jsonl")
    #expect(made.telemetry.sessionId == "s-1")
    #expect(made.telemetry.wallMilliseconds == 212_500)
    #expect(made.telemetry.unavailable.isEmpty)
    #expect(made.telemetry.startedAt == "2026-09-21T14:13:20Z")
  }

  @Test(
    "one lane's run names its lane; a review run names no single role — catches a record credited to the wrong agent"
  )
  func makeNamesTheRoleTheAgentsShare() throws {
    let oneLane = WorkflowTelemetry(
      outputTokens: 10,
      agents: [
        .init(label: "research:packages", returned: true),
        .init(label: "answer:packages:1", returned: true),
      ], unavailable: [])
    let amend = try DesignTelemetry.make(
      runId: "design-20260928T010000Z", phase: .amend, startedAt: Self.started,
      finishedAt: Self.started, workflow: oneLane, session: .notRequested)
    #expect(amend.phase.agentRole == .researchLane)
    #expect(amend.phase.lane == .packages)
    let review = WorkflowTelemetry(
      outputTokens: 10,
      agents: [
        .init(label: "review:challenger", returned: true),
        .init(label: "verify:challenger", returned: true),
      ], unavailable: [])
    let reviewed = try DesignTelemetry.make(
      runId: "design-20260928T010000Z", phase: .review, startedAt: Self.started,
      finishedAt: Self.started, workflow: review, session: .notRequested)
    #expect(reviewed.phase.agentRole == nil)
    #expect(reviewed.phase.lane == nil)
  }

  @Test(
    "unmeasured tokens and a missing transcript each carry a named reason — catches a silent gap in the record"
  )
  func makeNamesEveryGap() throws {
    let unmeasured = WorkflowTelemetry(outputTokens: nil, agents: [], unavailable: [])
    let noSession = try DesignTelemetry.make(
      runId: "design-20260928T010000Z", phase: .review, startedAt: Self.started,
      finishedAt: Self.started, workflow: unmeasured, session: .notRequested)
    #expect(noSession.phase.tokens == nil)
    #expect(noSession.phase.unavailable?.contains { $0.hasPrefix("output tokens: ") } == true)
    #expect(noSession.telemetry.unavailable.contains { $0.contains("--session") })
    let noPath = try DesignTelemetry.make(
      runId: "design-20260928T010000Z", phase: .review, startedAt: Self.started,
      finishedAt: Self.started, workflow: unmeasured,
      session: .recorded(sessionId: "s-1", transcriptPath: nil))
    #expect(noPath.telemetry.unavailable.contains { $0.contains("s-1") })
    let unreadable = try DesignTelemetry.make(
      runId: "design-20260928T010000Z", phase: .review, startedAt: Self.started,
      finishedAt: Self.started, workflow: unmeasured,
      session: .unreadable(sessionId: "s-2", reason: "no session record at x.json"))
    #expect(
      unreadable.telemetry.unavailable.contains { $0.contains("no session record at x.json") })
    #expect(unreadable.telemetry.transcriptPath == nil)
  }

  @Test(
    "a start after the finish is refused, a start at the finish is 0 ms — catches a negative wall time"
  )
  func makeRefusesAFutureStart() throws {
    let instant = try DesignTelemetry.make(
      runId: "design-20260928T010000Z", phase: .review, startedAt: Self.started,
      finishedAt: Self.started, workflow: Self.research, session: .notRequested)
    #expect(instant.phase.wallMilliseconds == 0)
    #expect(throws: DesignTelemetryError.self) {
      try DesignTelemetry.make(
        runId: "design-20260928T010000Z", phase: .review,
        startedAt: Self.started.addingTimeInterval(1), finishedAt: Self.started,
        workflow: Self.research, session: .notRequested)
    }
  }

  @Test(
    "only the phases a design workflow runs in are accepted, and a design run id has its fixed shape — catches a record filed under a phase no workflow ran"
  )
  func phaseAndRunIDAreClosed() throws {
    for phase in ["research", "review", "revise", "amend"] {
      #expect(try DesignTelemetry.phase(named: phase).rawValue == phase)
    }
    for phase in ["lint", "draft", "Research", "", "verify"] {
      #expect(throws: DesignTelemetryError.unknownPhase(phase)) {
        try DesignTelemetry.phase(named: phase)
      }
    }
    try DesignTelemetry.validateRunID("design-20260928T010000Z")
    for id in ["design-offline-queue", "20260928T010000Z", "design-20260928T010000Z/x", ""] {
      #expect(throws: DesignTelemetryError.invalidRunID(id)) {
        try DesignTelemetry.validateRunID(id)
      }
    }
  }

  @Test(
    "a design workflow result must carry schemaVersion 1 and a closed telemetry object — catches an unknown key, a missing object, a negative count or an unexplained null read as telemetry"
  )
  func decodeResultIsClosed() throws {
    let good =
      #"{"schemaVersion":1,"status":"complete","telemetry":{"outputTokens":7,"agents":[{"label":"review:challenger","returned":true}],"unavailable":[]}}"#
    #expect(try DesignTelemetry.decodeResult(Data(good.utf8)).outputTokens == 7)
    let bad = [
      #"{"schemaVersion":1,"status":"complete"}"#,
      #"{"status":"complete","telemetry":{"outputTokens":7,"agents":[],"unavailable":[]}}"#,
      #"{"schemaVersion":2,"telemetry":{"outputTokens":7,"agents":[],"unavailable":[]}}"#,
      #"{"schemaVersion":1,"telemetry":{"outputTokens":7,"agents":[],"unavailable":[],"costUSD":1}}"#,
      #"{"schemaVersion":1,"telemetry":{"agents":[],"unavailable":[]}}"#,
      #"{"schemaVersion":1,"telemetry":{"outputTokens":-1,"agents":[],"unavailable":[]}}"#,
      #"{"schemaVersion":1,"telemetry":{"outputTokens":null,"agents":[],"unavailable":[]}}"#,
      #"{"schemaVersion":1,"telemetry":{"outputTokens":7,"agents":[{"label":"x","returned":true,"ms":3}],"unavailable":[]}}"#,
      #"{"schemaVersion":1,"telemetry":null}"#,
      "not json",
    ]
    for text in bad {
      #expect(throws: DesignTelemetryError.self, "\(text)") {
        try DesignTelemetry.decodeResult(Data(text.utf8))
      }
    }
  }
}

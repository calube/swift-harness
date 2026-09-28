import Foundation
import SwiftGateDomain
import Testing

@Suite("Plan and ledger models")
struct LedgerModelTests {
  private static let samplePlan = PlanFile(
    schemaVersion: 1,
    slug: "2026-09-25-offline-order-queue",
    design: "docs/ordering/designs/offline-order-queue.md",
    designSha: "3f1c",
    approval: PlanFile.Approval(
      decision: .approve, designSha: "3f1c", at: Date(timeIntervalSince1970: 1_790_236_800)),
    clarifyChain: [
      PlanFile.ClarifyChainEntry(
        fromSha: "3f1c", toSha: "7a2d", at: Date(timeIntervalSince1970: 1_790_240_000))
    ],
    tier: .standard,
    resume: "planned; 7 tasks in 3 waves; next: sub-project 5 starts the first wave"
  )

  private static let sampleTask = LedgerTask(
    id: "offline-queue-core-reducer",
    deps: [],
    writeSet: [
      "Packages/OrderQueue/Sources/OrderQueueCore/",
      "Packages/OrderQueue/Tests/OrderQueueCoreTests/",
    ],
    gate: .push,
    tests: ["test-queued-orders-replay-in-submit-order"],
    covers: [
      "req-offline-queue-drains-on-reconnect", "test-queued-orders-replay-in-submit-order",
    ],
    estLines: 180,
    status: .pending,
    worktree: "../myapp-2026-09-25-offline-order-queue-offline-queue-core-reducer"
  )

  private static let sampleLedger = Ledger(
    schemaVersion: 1,
    resume: "…",
    maxParallel: 3,
    tasks: [sampleTask],
    waves: [["offline-queue-core-reducer"]]
  )

  @Test("plan.json round-trips byte-stable — catches schema drift")
  func planJSONRoundTrip() throws {
    let firstPass = try PlanFileJSON.encode(Self.samplePlan)
    let decoded = try PlanFileJSON.decode(firstPass)
    #expect(decoded == Self.samplePlan)
    let secondPass = try PlanFileJSON.encode(decoded)
    #expect(firstPass == secondPass)
  }

  @Test(
    "a plan.json seeded at frame, before any sha or tier is known, omits them and round-trips byte-stable — catches a sentinel sha passing for a real one"
  )
  func seedPlanRoundTrip() throws {
    let seed = PlanFile(
      schemaVersion: 1, slug: "2026-09-25-offline-order-queue",
      design: "docs/ordering/designs/offline-order-queue.md", designSha: nil, approval: nil,
      clarifyChain: [], tier: nil, resume: "framing")
    let firstPass = try PlanFileJSON.encode(seed)
    let text = String(decoding: firstPass, as: UTF8.self)
    #expect(!text.contains("designSha"))
    #expect(!text.contains("tier"))
    let decoded = try PlanFileJSON.decode(firstPass)
    #expect(decoded == seed)
    #expect(try PlanFileJSON.encode(decoded) == firstPass)
  }

  @Test("ledger.json round-trips byte-stable — catches schema drift")
  func ledgerJSONRoundTrip() throws {
    let firstPass = try LedgerJSON.encode(Self.sampleLedger)
    let decoded = try LedgerJSON.decode(firstPass)
    #expect(decoded == Self.sampleLedger)
    let secondPass = try LedgerJSON.encode(decoded)
    #expect(firstPass == secondPass)
  }

  @Test(
    "an unrecognized approval decision fails to decode, naming the value — catches a bad decision silently accepted"
  )
  func unknownApprovalDecisionRejected() throws {
    let validJSON = String(decoding: try PlanFileJSON.encode(Self.samplePlan), as: UTF8.self)
    #expect(validJSON.contains("\"approve\""))
    let corrupted = Data(validJSON.replacingOccurrences(of: "\"approve\"", with: "\"maybe\"").utf8)

    let error = #expect(throws: DecodingError.self) {
      try PlanFileJSON.decode(corrupted)
    }
    #expect(error != nil)
    #expect(String(describing: error).contains("maybe"))
  }

  @Test(
    "an unrecognized plan tier fails to decode, naming the value — catches a bad tier silently accepted"
  )
  func unknownPlanTierRejected() throws {
    let validJSON = String(decoding: try PlanFileJSON.encode(Self.samplePlan), as: UTF8.self)
    #expect(validJSON.contains("\"standard\""))
    let corrupted = Data(
      validJSON.replacingOccurrences(of: "\"standard\"", with: "\"extreme\"").utf8)

    let error = #expect(throws: DecodingError.self) {
      try PlanFileJSON.decode(corrupted)
    }
    #expect(error != nil)
    #expect(String(describing: error).contains("extreme"))
  }

  @Test(
    "an approval decision round-trips byte-stable for each case — catches a request-changes decision mangled on decode"
  )
  func approvalDecisionRoundTrips() throws {
    for decision in PlanFile.ApprovalDecision.allCases {
      let plan = PlanFile(
        schemaVersion: 1, slug: Self.samplePlan.slug, design: Self.samplePlan.design,
        designSha: "3f1c",
        approval: PlanFile.Approval(
          decision: decision, designSha: "3f1c", at: Date(timeIntervalSince1970: 1_790_236_800)),
        clarifyChain: [], tier: .standard, resume: "planned")
      let firstPass = try PlanFileJSON.encode(plan)
      let decoded = try PlanFileJSON.decode(firstPass)
      #expect(decoded == plan)
      #expect(try PlanFileJSON.encode(decoded) == firstPass)
    }
  }

  @Test(
    "a plan's tier round-trips byte-stable for each case — catches a quick or deep tier mangled on decode"
  )
  func planTierRoundTrips() throws {
    for tier in DesignTier.allCases {
      let plan = PlanFile(
        schemaVersion: 1, slug: Self.samplePlan.slug, design: Self.samplePlan.design,
        designSha: nil, approval: nil, clarifyChain: [], tier: tier, resume: "framing")
      let firstPass = try PlanFileJSON.encode(plan)
      let decoded = try PlanFileJSON.decode(firstPass)
      #expect(decoded == plan)
      #expect(try PlanFileJSON.encode(decoded) == firstPass)
    }
  }

  @Test(
    "an unrecognized task status is rejected, naming the value — catches an unknown build state passed through unexamined"
  )
  func unknownStatusRejected() throws {
    for invalid in ["finished", "done "] {
      let json = Data("\"\(invalid)\"".utf8)
      let error = #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(TaskStatus.self, from: json)
      }
      #expect(error != nil)
      #expect(String(describing: error).contains(invalid))
    }
  }

  @Test(
    "actualLines round-trips when present and is omitted, never a placeholder 0, when absent — catches a real count confused with an unset one"
  )
  func actualLinesPresentAndAbsentRoundTrip() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

    let withActuals = LedgerTask(
      id: "offline-queue-core-reducer", deps: [], writeSet: ["a/"], gate: .push,
      tests: ["test-a"], covers: ["test-a"], estLines: 180, status: .pending, worktree: "../w",
      actualLines: 210)
    let firstPass = try encoder.encode(withActuals)
    #expect(String(decoding: firstPass, as: UTF8.self).contains("\"actualLines\":210"))
    let decoded = try JSONDecoder().decode(LedgerTask.self, from: firstPass)
    #expect(decoded == withActuals)
    #expect(try encoder.encode(decoded) == firstPass)

    // Absent: sampleTask never set actualLines, so it stays nil and the key never appears.
    #expect(Self.sampleTask.actualLines == nil)
    let absentPass = try encoder.encode(Self.sampleTask)
    #expect(!String(decoding: absentPass, as: UTF8.self).contains("actualLines"))
    #expect(try JSONDecoder().decode(LedgerTask.self, from: absentPass).actualLines == nil)
  }

  @Test(
    "a negative actualLines fails to decode, naming the task — catches a corrupt worker report treated as real data"
  )
  func negativeActualLinesRejected() throws {
    let data = Data(
      String(
        decoding: try JSONEncoder().encode(
          LedgerTask(
            id: "offline-queue-core-reducer", deps: [], writeSet: ["a/"], gate: .push,
            tests: ["test-a"], covers: ["test-a"], estLines: 180, status: .pending,
            worktree: "../w", actualLines: 210)),
        as: UTF8.self
      ).replacingOccurrences(of: "210", with: "-5").utf8)

    let error = #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(LedgerTask.self, from: data)
    }
    #expect(error != nil)
    #expect(String(describing: error).contains("offline-queue-core-reducer"))
  }

  @Test(
    "an unrecognized gate tier fails to decode, naming the field — catches an invalid tier silently accepted"
  )
  func unknownGateTierRejected() throws {
    let validJSON = String(decoding: try LedgerJSON.encode(Self.sampleLedger), as: UTF8.self)
    #expect(validJSON.contains("\"push\""))
    let corrupted = Data(
      validJSON.replacingOccurrences(of: "\"push\"", with: "\"unknown-tier\"").utf8)

    let error = #expect(throws: DecodingError.self) {
      try LedgerJSON.decode(corrupted)
    }
    #expect(error != nil)
    let description = String(describing: error)
    #expect(description.contains("gate"))
    #expect(description.contains("unknown-tier"))
  }

  @Test(
    "a directory prefix overlaps a file under it, but two sibling files with a shared string prefix don't — catches false-disjoint waves"
  )
  func writeSetOverlap() {
    #expect(WriteSet.entriesOverlap("a/", "a/b.swift"))
    #expect(WriteSet.entriesOverlap("a/b.swift", "a/"))
    #expect(!WriteSet.entriesOverlap("a/b", "a/bc"))
    #expect(!WriteSet.entriesOverlap("a/bc", "a/b"))
    #expect(WriteSet.entriesOverlap("a/b", "a/b"))
    #expect(WriteSet.entriesOverlap("a/", "a/b/"))
  }

  @Test("two write sets overlap when any pair of their entries does")
  func writeSetsOverlap() {
    #expect(WriteSet.overlaps(["a/", "z/one.swift"], ["a/b.swift"]))
    #expect(!WriteSet.overlaps(["a/b", "z/one.swift"], ["a/bc", "z/two.swift"]))
  }

  @Test("a design-conflict report's evidence decodes as a claim citation")
  func reportEvidenceDecodesAsClaimCitation() throws {
    let report = TaskStatusReport(
      task: "offline-queue-core-reducer",
      state: "blocked",
      report: TaskStatusReport.Report(
        kind: "design-conflict",
        section: "decision",
        ids: ["req-offline-queue-drains-on-reconnect"],
        claim: "the queue cannot drain in one request: the endpoint caps batches at 20",
        evidence: [
          Citation(
            kind: .capture, loc: ".harness/runs/…/response.json", pin: "sha256:…",
            quote: "\"maxBatch\": 20")
        ]
      )
    )

    let data = try TaskStatusReportJSON.encode(report)
    let decoded = try TaskStatusReportJSON.decode(data)

    #expect(decoded == report)
    #expect(
      decoded.report.evidence == [
        Citation(
          kind: .capture, loc: ".harness/runs/…/response.json", pin: "sha256:…",
          quote: "\"maxBatch\": 20")
      ])
  }
}

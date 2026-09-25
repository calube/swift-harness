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
      decision: "approve", designSha: "3f1c", at: Date(timeIntervalSince1970: 1_790_236_800)),
    clarifyChain: [
      PlanFile.ClarifyChainEntry(
        fromSha: "3f1c", toSha: "7a2d", at: Date(timeIntervalSince1970: 1_790_240_000))
    ],
    tier: "standard",
    resume: "planned; 7 tasks in 3 waves; next: sub-project 5 starts the first wave"
  )

  private static let sampleTask = LedgerTask(
    id: "offline-queue-core-reducer",
    deps: [],
    writeSet: [
      "Packages/OrderQueue/Sources/OrderQueueCore/",
      "Packages/OrderQueue/Tests/OrderQueueCoreTests/",
    ],
    gate: "push",
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

  @Test("ledger.json round-trips byte-stable — catches schema drift")
  func ledgerJSONRoundTrip() throws {
    let firstPass = try LedgerJSON.encode(Self.sampleLedger)
    let decoded = try LedgerJSON.decode(firstPass)
    #expect(decoded == Self.sampleLedger)
    let secondPass = try LedgerJSON.encode(decoded)
    #expect(firstPass == secondPass)
  }

  @Test(
    "a status sub-project 5 has not invented yet round-trips unchanged — catches later build states dropped"
  )
  func unknownStatusPreserved() throws {
    let task = Self.sampleTask
    let withUnknownStatus = LedgerTask(
      id: task.id, deps: task.deps, writeSet: task.writeSet, gate: task.gate, tests: task.tests,
      covers: task.covers, estLines: task.estLines, status: TaskStatus(rawValue: "escalated"),
      worktree: task.worktree)
    let ledger = Ledger(
      schemaVersion: 1, resume: "…", maxParallel: 3, tasks: [withUnknownStatus],
      waves: [[task.id]])

    let data = try LedgerJSON.encode(ledger)
    let decoded = try LedgerJSON.decode(data)

    #expect(decoded.tasks[0].status == TaskStatus(rawValue: "escalated"))
    #expect(decoded.tasks[0].status.rawValue == "escalated")
    #expect(String(decoding: data, as: UTF8.self).contains("\"escalated\""))
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

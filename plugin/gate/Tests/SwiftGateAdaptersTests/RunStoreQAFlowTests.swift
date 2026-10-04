import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("run store kept flows")
struct RunStoreQAFlowTests {
  @Test(
    "a record writes 1 qa.flow per kept flow on the qa stream, with no plan or row, pointing at its gate.run — catches kept flows dropped by the record"
  )
  func keptFlowsRecorded() throws {
    let root = TestTemporaryDirectory.root
      .appending(path: "swiftgate-run-flows-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = HarnessEventFiles(root: root)
    let store = RunStore(worktreeRoot: root, events: files)
    let flow = QAFlowRecord(
      source: .xcuitest,
      steps: [
        QAFlowStep(n: 1, label: "Open com.example.SampleApp", offsetMs: 3, ok: true),
        QAFlowStep(n: 2, label: "Tap \"counter.increment\" Button", offsetMs: 4083, ok: false),
      ],
      video: "qa/xcuitest/C-testA/video.mp4", sheet: "qa/xcuitest/C-testA/sheet.png",
      flow: "counter", test: "C/testA()")

    try store.record(
      try RunReport(
        runID: "20261004T120000Z-00000002", durationMilliseconds: 40, tiers: [], findings: [],
        allowances: []),
      finishedAt: Date(timeIntervalSince1970: 1_790_000_000), command: "check ready",
      checkTier: .ready, flows: [flow])

    let gate = try HarnessEventJSON.decode(try #require(try files.read(.gate, runID: nil))).events
    let run = try #require(gate.first { $0.kind == .gateRun })
    let qa = try HarnessEventJSON.decode(try #require(try files.read(.qa, runID: nil))).events
    #expect(
      qa.map(\.payload)
        == [
          .qaFlow(QAFlowEvent(plan: nil, row: nil, requirement: nil, atBase: false, record: flow))
        ])
    #expect(qa.allSatisfy { $0.parentID == run.eventID })
  }
}

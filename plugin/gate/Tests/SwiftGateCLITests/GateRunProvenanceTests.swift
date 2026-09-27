import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

@Suite("gate run provenance")
struct GateRunProvenanceTests {
  @Test(
    "a gate run records the HEAD commit it started at in its report.json and history line, and no sha rather than a placeholder where there is no commit — catches a GREEN run no one can tie to the commit it proved"
  )
  func recordsHead() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-provenance-\(UUID().uuidString)", directoryHint: .isDirectory)
    let unborn = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-provenance-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: unborn)
    }
    let sha = "f6dba25c1e0a4b7d9e8f7a6b5c4d3e2f1a0b9c8d"
    let parts = GateRunParts(
      tiers: [try TierResult(tier: .t0, verdict: .green, durationMilliseconds: 1, testCounts: nil)])

    try await GateRun.execute(
      root: root, format: .json, command: "check push",
      git: FakeGit(changed: [], mergeBase: "base", revisions: ["HEAD": sha])
    ) { _ in parts }
    try await GateRun.execute(
      root: unborn, format: .json, command: "check push",
      git: FakeGit(changed: [], mergeBase: "base")
    ) { _ in parts }

    let store = RunStore(worktreeRoot: root)
    let record = try #require(try store.readHistory().records.last)
    let report = try RecordedRunReport.decode(
      Data(contentsOf: try store.runDirectory(for: record.runID).appending(path: "report.json")))
    let unbornRecord = try #require(
      try RunStore(worktreeRoot: unborn).readHistory().records.last)
    #expect(record.headCommit == sha)
    #expect(report.headCommit == sha)
    #expect(unbornRecord.command == "check push")
    #expect(unbornRecord.headCommit == nil)
  }
}

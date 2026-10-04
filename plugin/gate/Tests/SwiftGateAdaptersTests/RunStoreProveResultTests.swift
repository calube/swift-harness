import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("run store prove results")
struct RunStoreProveResultTests {
  private static func temporaryRoot() throws -> URL {
    let root = TestTemporaryDirectory.root
      .appending(path: "swiftgate-run-proofs-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private static func events(_ root: URL, _ stream: HarnessEventStream) throws -> [HarnessEvent] {
    guard let data = try HarnessEventFiles(root: root).read(stream, runID: nil) else { return [] }
    return try HarnessEventJSON.decode(data).events
  }

  private static func report() throws -> RunReport {
    try RunReport(
      runID: "20261004T120000Z-00000001", durationMilliseconds: 40, tiers: [], findings: [],
      allowances: [])
  }

  @Test(
    "a record writes 1 prove.result per proof on the test stream beside the test.results, each pointing at its gate.run — catches proofs dropped by the record"
  )
  func proofsRecorded() throws {
    let root = try Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RunStore(worktreeRoot: root, events: HarnessEventFiles(root: root))
    let proofs = [
      ProvedTest(
        test: "ProbeTests.PassXCTests/testDoubles", target: "ProbeTests", outcome: .proven,
        proofBase: "0a1b2c", assertion: ProveAssertion(file: "T/A.swift", line: 7, kind: .xctAssert)
      ),
      ProvedTest(
        test: "ProbeTests.PassSwiftTests/doubles", target: "ProbeTests", outcome: .passesReverted,
        proofBase: "0a1b2c", assertion: nil),
    ]
    let cases = [
      TestCaseResult(
        test: "ProbeTests.PassSwiftTests/doubles", target: "ProbeTests", tier: .t1,
        outcome: .passed, milliseconds: 1)
    ]

    try store.record(
      try Self.report(), finishedAt: Date(timeIntervalSince1970: 1_790_000_000),
      command: "check push", checkTier: .push, testResults: cases, proofs: proofs)

    let run = try #require(try Self.events(root, .gate).first { $0.kind == .gateRun })
    let stream = try Self.events(root, .test)
    let written = stream.filter { $0.kind == .proveResult }
    #expect(written.map(\.payload) == proofs.map { .proveResult(ProveResultEvent($0)) })
    #expect(written.allSatisfy { $0.parentID == run.eventID })
    #expect(stream.filter { $0.kind == .testResult }.count == 1)
  }

  @Test(
    "a test id the payload guard rejects is recorded as its hash, so the proof still lands — catches a proof dropped for its id"
  )
  func longIDHashed() throws {
    let root = try Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RunStore(worktreeRoot: root, events: HarnessEventFiles(root: root))
    let id = "T.Suite/" + String(repeating: "a", count: 600)

    try store.record(
      try Self.report(), finishedAt: Date(),
      proofs: [
        ProvedTest(test: id, target: "T", outcome: .proven, proofBase: nil, assertion: nil)
      ])

    let written = try Self.events(root, .test).compactMap { event -> ProveResultEvent? in
      guard case .proveResult(let result) = event.payload else { return nil }
      return result
    }
    #expect(written.count == 1)
    #expect(written.first?.testHashed == true)
    #expect(written.first?.test.hasPrefix("sha256:") == true)
  }
}

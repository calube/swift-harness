import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("sim verify")
struct SimVerifyTests {
  static let runID = "20261004T120000Z-1a2b3c4d"
  static let worktree = "/repos/app"
  static let head = "0123456789abcdef0123456789abcdef01234567"
  static let finishedAt = Date(timeIntervalSince1970: 1_791_115_800)

  let root = TestTemporaryDirectory.root.appending(
    path: "sim-verify-\(UUID().uuidString)", directoryHint: .isDirectory)
  var leases: SimLeaseStore { SimLeaseStore(directory: root.appending(path: "locks/sim-leases")) }
  var historyFile: URL { root.appending(path: "state/runs/history.jsonl") }

  func simDirectory(_ runID: String = runID) -> URL {
    root.appending(path: "state/runs/\(runID)/sim", directoryHint: .isDirectory)
  }

  static func lease(
    _ runID: String = runID, worktree: String = worktree, holderPID: Int32 = 4242
  ) -> SimLease {
    SimLease(
      runID: runID, worktree: worktree, udid: "MADE-1", holderPID: holderPID,
      session: SimSession.agentDeviceSessionName(runID: runID))
  }

  /// A run as `sim up` leaves it, plus 1 step per assert as `sim snap` records it with the
  /// captured tree.
  func recorded(_ runID: String = runID, asserts: [String?]) throws {
    let directory = simDirectory(runID)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try SimSession(
      agentDeviceVersion: AgentDevicePin.version, udid: "MADE-1", deviceType: "iPhone 17",
      runtime: "com.apple.CoreSimulator.SimRuntime.iOS-26-2", bundleID: "com.example.SampleApp",
      scenario: nil, headCommit: Self.head, startedAt: Date(timeIntervalSince1970: 1_791_115_200)
    ).encoded().write(to: directory.appending(path: SimSession.fileName))
    let store = SimRunStore(simDirectory: directory)
    let tree = try Fixture.data("AgentDevice/snapshot.stdout")
    for assert in asserts {
      let staging = try store.stage()
      try Data("png bytes".utf8).write(to: staging.screenshot)
      _ = try store.commit(staging, treeJSON: tree) { n in
        SimStep(
          n: n, label: "step \(n)", assert: assert, screenshot: SimStep.screenshotPath(n: n),
          tree: SimStep.treePath(n: n), settled: true, elapsedMs: 700)
      }
    }
  }

  func verify(
    runID: String? = runID, worktree: String = worktree,
    head: SimCheckoutHead = .commit(head), alive: Set<Int32> = [4242]
  ) -> Result<SimVerified, SimVerifyFailure> {
    let directories = root
    return SimVerify(
      dependencies: SimVerify.Dependencies(
        leases: leases, isAlive: { alive.contains($0) }, clock: VirtualHoldClock().clock,
        now: { Self.finishedAt })
    ).run(
      SimVerify.Request(
        worktree: worktree, runID: runID, checkoutHead: head,
        simDirectory: {
          directories.appending(path: "state/runs/\($0)/sim", directoryHint: .isDirectory)
        }, historyFile: historyFile))
  }

  static func report(_ result: Result<SimVerified, SimVerifyFailure>) throws -> SimVerifyReport {
    guard case .success(let verified) = result else {
      Issue.record("expected a judged run, got \(result)")
      throw CancellationError()
    }
    return verified.report
  }

  func history() -> [RunHistoryRecord] {
    RunHistoryJSON.decode((try? Data(contentsOf: historyFile)) ?? Data()).records
  }

  func writtenReport(_ runID: String = runID) throws -> [String: Any] {
    let data = try Data(contentsOf: simDirectory(runID).appending(path: SimVerifyReport.fileName))
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  @Test(
    "a recorded run with its evidence on disk is GREEN, writes sim/report.json and a history line naming the run and verdict"
  )
  func green() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    try leases.write(Self.lease())
    try recorded(asserts: [nil, "Increment"])
    let report = try Self.report(verify())
    #expect(report.verdict == .green)
    #expect(report.stepCount == 2)
    let written = try writtenReport()
    #expect(written["schemaVersion"] as? Int == 1)
    #expect(written["verdict"] as? String == "GREEN")
    #expect(written["stepCount"] as? Int == 2)
    let line = try #require(history().last)
    #expect(line.runID == Self.runID)
    #expect(line.verdict == .green)
    #expect(line.command == "sim verify")
    #expect(line.headCommit == Self.head)
    #expect(line.finishedAt == Self.finishedAt)
  }

  @Test(
    "the same run with a step's tree deleted is RED sim.evidence-missing naming the file, in the report and the history line"
  )
  func treeDeleted() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    try leases.write(Self.lease())
    try recorded(asserts: [nil, "Increment"])
    try FileManager.default.removeItem(at: simDirectory().appending(path: SimStep.treePath(n: 2)))
    let report = try Self.report(verify())
    #expect(report.verdict == .red)
    try #require(report.findings.map(\.rule) == [.evidenceMissing])
    #expect(report.findings[0].message.contains("steps/002.tree.json"))
    #expect(try writtenReport()["verdict"] as? String == "RED")
    #expect(history().last?.verdict == .red)
    #expect(history().last?.findingCount == 1)
  }

  @Test("an assert text absent from the recorded tree is RED sim.assert-absent")
  func assertAbsent() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    try leases.write(Self.lease())
    try recorded(asserts: ["Counter: 42"])
    #expect(try Self.report(verify()).findings.map(\.rule) == [.assertAbsent])
  }

  @Test("a HEAD that moved since sim up is RED sim.stale-head")
  func staleHead() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    try leases.write(Self.lease())
    try recorded(asserts: [nil])
    let report = try Self.report(
      verify(head: .commit("fedcba9876543210fedcba9876543210fedcba98")))
    #expect(report.findings.map(\.rule) == [.staleHead])
  }

  @Test(
    "a run with no step log is RED sim.no-steps, and a run directory that isn't there is BLOCKED and recorded, never GREEN"
  )
  func emptyAndUnreadable() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    try recorded(asserts: [])
    let empty = try Self.report(verify())
    #expect(empty.findings.map(\.rule) == [.noSteps])

    let missing = try Self.report(verify(runID: "20261004T130000Z-00000000"))
    #expect(missing.verdict == .blocked)
    #expect(missing.blocked?.contains(SimSession.fileName) == true)
    #expect(history().last?.runID == "20261004T130000Z-00000000")
    #expect(history().last?.verdict == .blocked)
  }

  @Test("a step log that doesn't decode is BLOCKED naming the log, never GREEN")
  func corruptLog() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    try recorded(asserts: [nil])
    let log = simDirectory().appending(path: SimStep.logFileName)
    let handle = try FileHandle(forWritingTo: log)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"n\":2}\n".utf8))
    try handle.close()
    let report = try Self.report(verify())
    #expect(report.verdict == .blocked)
    #expect(report.blocked?.contains(SimStep.logFileName) == true)
  }

  @Test(
    "a lease from another worktree is refused with sim.not-owner and writes no report or history line — catches one worktree judging another's run"
  )
  func otherWorktree() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    try leases.write(Self.lease(worktree: "/repos/app-other"))
    try recorded(asserts: [nil])
    guard case .failure(let failure) = verify() else {
      Issue.record("another worktree's run was judged")
      return
    }
    #expect(failure.rule == .notOwner)
    #expect(failure.message.contains("/repos/app-other"))
    #expect(
      !FileManager.default.fileExists(
        atPath: simDirectory().appending(path: SimVerifyReport.fileName).path))
    #expect(history().isEmpty)
  }

  @Test(
    "a named run whose lease sim down removed is still judged from its run directory"
  )
  func afterDown() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    try recorded(asserts: [nil])
    #expect(try Self.report(verify()).verdict == .green)
  }

  @Test(
    "with no run id verify takes this worktree's newest live lease, skipping another worktree's and a dead holder's"
  )
  func newestOwnLease() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let older = "20261004T110000Z-00000001"
    let dead = "20261004T130000Z-00000002"
    let foreign = "20261004T140000Z-00000003"
    try leases.write(Self.lease(older))
    try leases.write(Self.lease(dead, holderPID: 999))
    try leases.write(Self.lease(foreign, worktree: "/repos/app-other"))
    try recorded(older, asserts: [nil])
    let report = try Self.report(verify(runID: nil))
    #expect(report.runID == older)
    #expect(report.verdict == .green)
  }

  @Test("with no run id and no live lease of its own, verify is refused naming the run id to pass")
  func noLease() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    try leases.write(Self.lease(worktree: "/repos/app-other"))
    guard case .failure(let failure) = verify(runID: nil) else {
      Issue.record("verify judged a run it had no lease for")
      return
    }
    #expect(failure.rule == .environment)
    #expect(failure.verdict == .blocked)
    #expect(failure.message.contains("run id"))
    #expect(history().isEmpty)
  }
}

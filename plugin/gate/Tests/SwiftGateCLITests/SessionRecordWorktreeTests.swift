import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// A brownfield clone with a plan checkout and a task worktree beside it, laid out as `git
/// worktree add` leaves them: each linked worktree's `.git` names its git dir, whose `commondir`
/// points back at the clone's. The SessionStart hook ran in the main checkout.
private struct LinkedClone {
  static let session = EventsIngestCommandTests.plainSession

  let base: URL
  let clone: URL
  let planCheckout: URL
  let taskWorktree: URL

  init() throws {
    base = TestTemporaryDirectory.root
      .appending(path: "swiftgate-linked-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    clone = base.appending(path: "memos", directoryHint: .isDirectory)
    planCheckout = base.appending(path: "memos-spec", directoryHint: .isDirectory)
    taskWorktree = base.appending(path: "memos-spec-store", directoryHint: .isDirectory)
    let common = clone.appending(path: ".git", directoryHint: .isDirectory)
    try Self.write(
      common.appending(path: StateRootResolver.commonConfigFile), AllowCommandTests.config)
    for worktree in [planCheckout, taskWorktree] {
      let gitDir = common.appending(
        path: "worktrees/\(worktree.lastPathComponent)", directoryHint: .isDirectory)
      try Self.write(worktree.appending(path: ".git"), "gitdir: \(gitDir.path)\n")
      try Self.write(gitDir.appending(path: "commondir"), "../..\n")
    }
    let transcripts = base.appending(path: "transcripts", directoryHint: .isDirectory)
    try FileManager.default.copyItem(
      at: Fixture.directory.appending(path: "Transcripts", directoryHint: .isDirectory),
      to: transcripts)
    try SessionRecordStore(worktreeRoot: clone).write(
      try SessionRecord(
        sessionId: Self.session, recordedAt: Date(timeIntervalSince1970: 1_790_000_000),
        pluginRoot: base.path, pluginVersion: "0.1.0",
        treeHash: String(repeating: "a", count: 64),
        transcriptPath: transcripts.appending(path: "\(Self.session).jsonl").path))
  }

  static func write(_ url: URL, _ text: String) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }

  func remove() { try? FileManager.default.removeItem(at: base) }

  func ingest(from root: URL) -> EventsCommandOutput {
    EventsIngestRun.make(
      options: EventsIngestRun.Options(
        session: Self.session, workflowTranscripts: nil, role: .orchestrator, task: nil,
        buildRun: nil),
      root: root)
  }

  func sessionRecordFindings(from root: URL, session: String) async throws -> [Finding] {
    let runner = FakeProcessRunner { invocation throws(ProcessRunnerError) in
      throw .launchFailed(executable: invocation.executable, reason: "not on this test machine")
    }
    let parts = try await DoctorRun.run(
      root: root, sessionID: session, swiftPM: FakeSwiftPM(serving: []), runner: runner)
    return parts.findings.filter { $0.ruleID == Doctor.sessionRecordRuleID }
  }
}

@Suite("session records from a brownfield clone's linked worktrees")
struct SessionRecordWorktreeTests {
  @Test(
    "events ingest finds the session the main checkout recorded from the plan checkout and from a task worktree — catches the memos run's own usage ingest failing with no session record"
  )
  func ingestFindsTheSessionFromEveryWorktree() throws {
    let clone = try LinkedClone()
    defer { clone.remove() }
    for root in [clone.planCheckout, clone.taskWorktree] {
      let output = clone.ingest(from: root)
      #expect(output.status == 0, "\(root.lastPathComponent): \(output.stderr)")
      #expect(!output.stderr.contains("no session record"), "\(output.stderr)")
    }
  }

  @Test(
    "doctor --session finds the session the main checkout recorded from the plan checkout and from a task worktree, and still names an unknown session — catches doctor.session-record firing from every linked worktree"
  )
  func doctorFindsTheSessionFromEveryWorktree() async throws {
    let clone = try LinkedClone()
    defer { clone.remove() }
    for root in [clone.planCheckout, clone.taskWorktree] {
      let findings = try await clone.sessionRecordFindings(
        from: root, session: LinkedClone.session)
      #expect(findings.isEmpty, "\(root.lastPathComponent): \(findings.map(\.message))")
    }
    let unknown = try await clone.sessionRecordFindings(
      from: clone.planCheckout, session: "0f0f0f0f-0000-4000-8000-000000000000")
    #expect(unknown.map(\.ruleID) == [Doctor.sessionRecordRuleID])
  }
}

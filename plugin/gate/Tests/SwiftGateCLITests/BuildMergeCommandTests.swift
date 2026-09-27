import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

private struct FixedClock: BuildClock {
  func now() -> Date { Date(timeIntervalSince1970: 1_790_000_000) }
}

@Suite("build merge --json")
struct BuildMergeCommandTests {
  @Test(
    "a session that doesn't hold the plan's lock gets reason not-held in the JSON, and a merge with no reason omits the key — catches a refusal a caller can only tell apart by its wording"
  )
  func notHeldNamesItsReason() async throws {
    let common = FileManager.default.temporaryDirectory
      .appending(path: "build-merge-\(UUID().uuidString)/app/.git", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: common, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(
        at: common.deletingLastPathComponent().deletingLastPathComponent())
    }
    let merger = FakeMergeRunner()
    let workspace = FakeGitWorkspace()

    let report = await BuildMergeRun.run(
      slug: "search", task: "t1", undo: false, session: "not-the-holder",
      git: FakeGit(commonDirectory: common.path), workspace: workspace, merger: merger,
      clock: FixedClock())
    let json = BuildMergeRun.render(report, format: .json)
    let merged = BuildMergeRun.render(
      BuildMergeReport(
        command: BuildMerge.mergeCommand, plan: "search", task: "t1", status: .merged,
        verdict: .green, message: "merged"), format: .json)

    #expect(report.status == .notHeld, "\(report.message)")
    #expect(report.reason == .notHeld)
    #expect(json.contains(#""reason" : "not-held""#))
    #expect(!merged.contains(#""reason""#))
    #expect(merger.calls == [])
    #expect(workspace.calls == [])
  }
}

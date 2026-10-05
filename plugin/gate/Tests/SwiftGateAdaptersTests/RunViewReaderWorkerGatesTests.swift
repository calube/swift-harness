import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// What `git rev-list` printed in the captured clone for each task's branch and its fixer's, one
/// file per task under the fixture's `branch-commits/`, named by the task's branch with its `/`
/// spelled `_`. A task with no file reads as one git can't name.
struct CapturedBranchCommits: BranchCommitReading {
  let directory: URL

  init(fixture: String) {
    directory = Fixture.gateDirectory.appending(
      path: "Tests/Fixtures/RunView/\(fixture)/branch-commits", directoryHint: .isDirectory)
  }

  func exclusiveCommits(of branches: [String]) -> Set<String>? {
    guard let branch = branches.first else { return nil }
    let file = directory.appending(
      path: branch.replacingOccurrences(of: "/", with: "_") + ".txt")
    guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
    return Set(text.split(separator: "\n").map(String.init))
  }
}

/// No branch git can name, as in a clone whose task branches were all deleted.
private struct NoBranchCommits: BranchCommitReading {
  func exclusiveCommits(of branches: [String]) -> Set<String>? { nil }
}

@Suite("run view reader: crediting a worker's gate run to its checkout's task")
struct RunViewReaderWorkerGatesTests {
  static let validation = "spec-validation"
  /// Each worker gate run of the 3 build workers that ran beside the validation task, by the
  /// task whose branch holds its head commit.
  static let threadRuns = [
    "20261005T130655Z-4b0d65c5", "20261005T130820Z-ddefb3de", "20261005T130840Z-21b90973",
    "20261005T130902Z-33499988", "20261005T131026Z-920fb68f",
  ]
  static let rootRuns = [
    "20261005T130646Z-a106b05b", "20261005T130849Z-d350dc3e", "20261005T131027Z-a485cb8d",
    "20261005T131052Z-d7cb9920", "20261005T131104Z-171e8b04",
  ]
  static let listRuns = [
    "20261005T130642Z-759871db", "20261005T130820Z-9d38f596", "20261005T130844Z-ea321f3d",
  ]
  /// A `hook stop` run with no head commit, while 4 task windows were open.
  static let hookStop = "20261005T130656Z-168da1e8"

  static func tasks(_ view: RunView) -> [String: String] {
    Dictionary(
      view.gates.map { ($0.runID, $0.task ?? "none") }, uniquingKeysWith: { first, _ in first })
  }

  @Test(
    "4 tasks in progress at once: each worker's slice and test-only runs go to the task whose branch holds their head, none to the validation task that ran beside them — catches worker gates credited to whichever task's window held them"
  )
  func creditsRunsByTheirHeadsBranch() throws {
    let clone = try BlockedClone(BlockedClone.parallelWorkers)
    defer { clone.remove() }
    let view = try clone.view()
    let tasks = Self.tasks(view)

    for runID in Self.threadRuns { #expect(tasks[runID] == "chat-thread", "\(runID)") }
    for runID in Self.rootRuns { #expect(tasks[runID] == "chat-root", "\(runID)") }
    for runID in Self.listRuns { #expect(tasks[runID] == "chat-list", "\(runID)") }
    #expect(!view.gates.contains { $0.task == Self.validation })
    #expect(!view.spans.contains { $0.phase == .gate && $0.task == Self.validation })
    #expect(
      view.spans.contains {
        $0.id == "gate:20261005T130655Z-4b0d65c5" && $0.parent == "task:chat-thread"
      })
  }

  @Test(
    "a run no checkout, head or return singles out, while 4 task windows are open, shows with no task under the run — catches an ambiguous run guessed onto 1 of the overlapping tasks or dropped"
  )
  func showsAnAmbiguousRunUnattributed() throws {
    let clone = try BlockedClone(BlockedClone.parallelWorkers)
    defer { clone.remove() }
    let input = try clone.input()
    #expect(input.unattributedGateRuns.contains(Self.hookStop))
    #expect(input.workerGateRuns[Self.hookStop] == nil)

    let view = RunViewBuilder.build(input)
    let gate = try #require(view.gates.first { $0.runID == Self.hookStop })
    #expect(gate.task == nil)
    let span = try #require(view.spans.first { $0.id == "gate:\(Self.hookStop)" })
    #expect(span.parent == "run")
  }

  @Test(
    "with no branch git can name, a run whose head only its task branch held is unattributed, while a head the task's return or checked return names still goes to it — catches a deleted branch's runs falling back to the overlapping windows' guess"
  )
  func leavesUnownedHeadsUnattributedWithoutBranches() throws {
    let clone = try BlockedClone(BlockedClone.parallelWorkers)
    defer { clone.remove() }
    let input = try clone.input(branchCommits: NoBranchCommits())

    for runID in Self.threadRuns {
      #expect(input.workerGateRuns[runID] == nil, "\(runID)")
      #expect(input.unattributedGateRuns.contains(runID), "\(runID)")
    }
    for runID in Self.rootRuns { #expect(input.workerGateRuns[runID] == "chat-root", "\(runID)") }
    for runID in Self.listRuns { #expect(input.workerGateRuns[runID] == "chat-list", "\(runID)") }
    // Its head is the commit chat-thread's checked return named.
    #expect(input.workerGateRuns["20261005T131222Z-1d30faa8"] == "chat-thread")
    #expect(!input.workerGateRuns.values.contains(Self.validation))
  }
}

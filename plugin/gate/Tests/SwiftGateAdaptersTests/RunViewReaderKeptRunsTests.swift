import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// The first tic-tac-toe trial's clone after `run checkout remove`: its plan state and the 3
/// `qa run` directories the removal kept, in the clone's common state root, with a user's tree
/// that still commits its own `.swiftgate.toml`.
private struct KeptRunsClone {
  static let buildRun = "20261005T004845Z-62589e1a"
  static let plan = "spec"
  static let qaRuns: Set<String> = [
    "20261005T005653Z-37ebb9c9", "20261005T010144Z-9350394a", "20261005T010428Z-75c783e4",
  ]

  let parent: URL
  let user: URL
  let common: URL

  init() throws {
    let captured = Fixture.gateDirectory.appending(
      path: "Tests/Fixtures/RunView/tic-tac-toe-1-kept-runs", directoryHint: .isDirectory)
    let files = FileManager.default
    parent = TestTemporaryDirectory.root.appending(
      path: "run-view-kept-runs-\(UUID().uuidString)", directoryHint: .isDirectory
    ).resolvingSymlinksInPath()
    user = parent.appending(path: "repo", directoryHint: .isDirectory)
    common = user.appending(path: ".git", directoryHint: .isDirectory)
    let harness = common.appending(path: "swift-harness", directoryHint: .isDirectory)
    let planDirectory = harness.appending(path: "plans/\(Self.plan)", directoryHint: .isDirectory)
    let run = planDirectory.appending(path: "build/\(Self.buildRun)", directoryHint: .isDirectory)
    try files.createDirectory(at: run, withIntermediateDirectories: true)
    try Data().write(to: harness.appending(path: "config.toml"))
    try files.copyItem(
      at: Fixture.gateDirectory.appending(
        path: "Tests/Fixtures/BrownfieldTrial/starter-swiftgate.toml"),
      to: user.appending(path: ".swiftgate.toml"))
    let copies: [(String, URL)] = [
      ("ledger.json", planDirectory.appending(path: "ledger.json")),
      ("plan.json", planDirectory.appending(path: "plan.json")),
      ("clock.json", planDirectory.appending(path: "clock.json")),
      ("run.json", run.appending(path: "run.json")),
      ("ledger-events.jsonl", run.appending(path: "events.jsonl")),
      ("returns", run.appending(path: "returns")),
      ("runs", harness.appending(path: "runs")),
      // The store this checkout's own state root reads.
      ("events", user.appending(path: ".harness/events")),
    ]
    try files.createDirectory(
      at: user.appending(path: ".harness", directoryHint: .isDirectory),
      withIntermediateDirectories: true)
    for (name, target) in copies {
      try files.copyItem(at: captured.appending(path: name), to: target)
    }
  }

  func read() throws -> RunViewInput {
    try RunViewReader(
      commonDirectory: common, stateRoot: StateRootResolver.resolve(worktree: user),
      profile: StateRootResolver.profile(worktree: user)
    ).read(buildRun: Self.buildRun)
  }

  func remove() { try? FileManager.default.removeItem(at: parent) }
}

@Suite("run view reader: the qa runs a removed plan checkout kept")
struct RunViewReaderKeptRunsTests {
  @Test(
    "a report read from a checkout whose committed config keeps its state in the tree reads each qa run's report from the clone's kept runs — catches every validation report listed as missing after run checkout remove"
  )
  func readsKeptQARuns() throws {
    let clone = try KeptRunsClone()
    defer { clone.remove() }
    #expect(StateRootResolver.resolve(worktree: clone.user) == .tree(clone.user))

    let input = try clone.read()

    #expect(Set(input.qaRuns.keys) == KeptRunsClone.qaRuns)
    #expect(input.qaRuns.values.allSatisfy { $0.report != nil })
    #expect(
      !input.damage.contains { $0.source.hasSuffix("qa/report.json") }, "\(input.damage)")
    let validation = try #require(RunViewBuilder.build(input).validation)
    #expect(validation.rows.count == 3)
    #expect(validation.rows.allSatisfy { $0.check != nil && $0.message != nil })
  }
}

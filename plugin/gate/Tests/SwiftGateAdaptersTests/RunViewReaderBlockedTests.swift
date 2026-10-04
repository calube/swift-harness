import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// A brownfield clone in a temp directory holding the captured `brownfield-blocked` run: its
/// shared store, its plan state, and each task worktree with its own run store under its git dir,
/// as `git worktree add` lays them out. Nothing here reads or writes this checkout's state.
private struct BlockedClone {
  static let captured = Fixture.gateDirectory.appending(
    path: "Tests/Fixtures/RunView/brownfield-blocked", directoryHint: .isDirectory)
  static let buildRun = "20261004T124141Z-c3747b7a"
  static let plan = "spec"
  static let store = "share-view-limit-store"
  static let web = "share-view-limit-web"

  let parent: URL
  let common: URL
  var state: StateRoot { .gitDir(common) }

  init() throws {
    let files = FileManager.default
    parent = TestTemporaryDirectory.root.appending(
      path: "run-view-blocked-\(UUID().uuidString)", directoryHint: .isDirectory
    ).resolvingSymlinksInPath()
    common = parent.appending(path: "memos-3/.git", directoryHint: .isDirectory)
    let harness = common.appending(path: "swift-harness", directoryHint: .isDirectory)
    let planDirectory = harness.appending(path: "plans/\(Self.plan)", directoryHint: .isDirectory)
    let run = planDirectory.appending(path: "build/\(Self.buildRun)", directoryHint: .isDirectory)
    try files.createDirectory(at: run, withIntermediateDirectories: true)
    try Data().write(to: harness.appending(path: "config.toml"))
    let copies: [(String, URL)] = [
      ("events", harness.appending(path: "events")),
      ("ledger.json", planDirectory.appending(path: "ledger.json")),
      ("plan.json", planDirectory.appending(path: "plan.json")),
      ("clock.json", planDirectory.appending(path: "clock.json")),
      ("run.json", run.appending(path: "run.json")),
      ("ledger-events.jsonl", run.appending(path: "events.jsonl")),
      ("returns", run.appending(path: "returns")),
    ]
    for (name, target) in copies {
      try files.copyItem(at: Self.captured.appending(path: name), to: target)
    }
    let worktrees = Self.captured.appending(path: "worktrees", directoryHint: .isDirectory)
    for name in try files.contentsOfDirectory(atPath: worktrees.path) where !name.hasPrefix(".") {
      let checkout = parent.appending(path: name, directoryHint: .isDirectory)
      let gitDir = common.appending(path: "worktrees/\(name)", directoryHint: .isDirectory)
      try files.createDirectory(at: checkout, withIntermediateDirectories: true)
      try files.createDirectory(
        at: gitDir.appending(path: "swift-harness"), withIntermediateDirectories: true)
      try Data("gitdir: \(gitDir.path)\n".utf8).write(to: checkout.appending(path: ".git"))
      try Data("../..\n".utf8).write(to: gitDir.appending(path: "commondir"))
      try files.copyItem(
        at: worktrees.appending(path: "\(name)/runs"),
        to: gitDir.appending(path: "swift-harness/runs"))
    }
  }

  func view() throws -> RunView {
    let input = try RunViewReader(commonDirectory: common, stateRoot: state, profile: .brownfield)
      .read(buildRun: Self.buildRun)
    return RunViewBuilder.build(input)
  }

  func remove() { try? FileManager.default.removeItem(at: parent) }
}

@Suite("run view reader: a brownfield run with blocked tasks")
struct RunViewReaderBlockedTests {
  @Test(
    "2 concurrent tasks' worker gate runs in the clone's shared store read with the task whose worktree holds them — catches worker gates dropped when task windows overlap"
  )
  func attributesWorkerRunsByTheirWorktree() throws {
    let clone = try BlockedClone()
    defer { clone.remove() }
    let view = try clone.view()
    let tasks = Dictionary(
      view.gates.map { ($0.runID, $0.task ?? "none") }, uniquingKeysWith: { first, _ in first })
    #expect(tasks["20261004T124437Z-d7c9ce0b"] == BlockedClone.web)
    #expect(tasks["20261004T124503Z-79e036f7"] == BlockedClone.web)
    #expect(tasks["20261004T124744Z-9d7ec113"] == BlockedClone.store)
    #expect(tasks["20261004T124847Z-cc87cdd0"] == BlockedClone.store)
    let storeGate = try #require(view.gates.first { $0.runID == "20261004T124744Z-9d7ec113" })
    let failure = try #require(storeGate.failure)
    #expect(failure.stage == .worker)
    #expect(failure.checkTier == .slice)
    let finding = try #require(failure.findings.first)
    #expect(finding.rule == "neutral.lint")
    #expect(finding.file == "store/test/memo_share_test.go")
    #expect(finding.line == 212)
    #expect(
      failure.report
        == "<git dir of memos-3-spec-share-view-limit-store>/swift-harness/runs/20261004T124744Z-9d7ec113/report.json"
    )
    #expect(try RunViewGuard.rejection(of: view) == nil)
  }

  @Test(
    "a task that ended blocked with a GREEN last gate and no stored return says so on its task, and its task span ends there halted — catches a blocked task whose every span reads ok"
  )
  func blockedTaskSaysWhy() throws {
    let clone = try BlockedClone()
    defer { clone.remove() }
    let view = try clone.view()
    for (task, gate) in [
      (BlockedClone.web, "20261004T124503Z-79e036f7"),
      (BlockedClone.store, "20261004T124847Z-cc87cdd0"),
    ] {
      let row = try #require(view.tasks.first { $0.id == task })
      let block = try #require(row.blocked, "\(task)")
      #expect(block.cause == .returnNotStored, "\(task)")
      #expect(block.halt == .question, "\(task)")
      #expect(block.gateRun == gate, "\(task)")
      let span = try #require(view.spans.first { $0.phase == .task && $0.task == task })
      #expect(span.outcome == .halted, "\(task)")
      #expect(span.end == block.at, "\(task)")
    }
    #expect(view.tasks.filter { $0.status != .blocked }.allSatisfy { $0.blocked == nil })
  }
}

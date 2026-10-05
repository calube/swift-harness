import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// `qa adopt` over a captured trial's plan state at the moment its validation task returned: the
/// trial's table, whose every row runs after the screens tasks, and its build run's events up to
/// then, with 2 tasks' returns checked and waiting on the `--at-base` run. The orchestrator then sat
/// idle for 118 s with both ready.
@Suite("qa adopt: the merges it unblocks")
struct QAAdoptUnblocksTests {
  static let directory = "BrownfieldTrial"
  static let buildRun = "20261005T110258Z-f7966a8c"
  static let validationTask = "spec-validation"

  /// The captured build events before the validation task was marked done.
  static func events() throws -> [String] {
    let lines = try Fixture.text("\(directory)/send-money-7-build-events.jsonl")
      .split(separator: "\n").map(String.init)
    let done = try #require(
      lines.firstIndex {
        $0.contains("\"task\":\"\(validationTask)\"") && $0.contains("\"to\":\"done\"")
      })
    return Array(lines[..<done])
  }

  /// Each task's ledger status after the captured transitions in `lines`, from `pending`; the
  /// contract task, which landed before the build run, is `done`.
  static func statuses(_ lines: [String], table: ValidationTable) -> [String: TaskStatus] {
    var statuses = Dictionary(
      (table.rows.flatMap(\.runsAfter) + [validationTask]).map { ($0, TaskStatus.pending) },
      uniquingKeysWith: { first, _ in first })
    statuses["spec-contract"] = .done
    for event in BuildEventJSON.decode(Data(lines.map { $0 + "\n" }.joined().utf8)).events {
      if case .transition(let transition) = event { statuses[transition.task] = transition.to }
    }
    return statuses
  }

  @Test(
    "adopting the validation worktree names the 2 tasks whose checked returns waited on the at-base run, in the order they were checked, each with the exact build merge command for the session — catches the orchestrator ending its turn with a task ready to merge"
  )
  func namesTheMergesItUnblocks() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    let table = try ValidationTableJSON.decode(
      try Fixture.data("\(Self.directory)/send-money-7-validation.json"))
    let lines = try Self.events()
    try repo.plan(table.rows, tasks: Self.statuses(lines, table: table))
    let build = repo.planDirectory.appending(
      path: "build/\(Self.buildRun)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
    try Data(lines.map { $0 + "\n" }.joined().utf8)
      .write(to: build.appending(path: "events.jsonl"))
    let worktree = repo.root.deletingLastPathComponent()
      .appending(path: repo.root.lastPathComponent + "-validation", directoryHint: .isDirectory)
    defer { TestTemporaryDirectory.remove(worktree) }
    try await repo.git("worktree", "add", "-q", "-b", "validation", worktree.path, "main")
    try QAAdoptCommandTests.prepare(
      worktree, plan: QARepo.slug, files: ["send-success.flow.json": "{}\n"])

    let report = await QAAdoptRun.run(
      worktree: worktree.path, root: repo.root,
      git: LiveGit(runner: repo.runner, repositoryRoot: repo.root.path), runner: repo.runner,
      session: "session-1")

    #expect(report.verdict == .green, "\(report.message)")
    #expect(report.unblocks.map(\.task) == ["views", "amount-entry"], "\(report.unblocks)")
    #expect(
      report.unblocks.first?.next
        == "\"$SG\" build merge \(QARepo.slug) views --session session-1 --json")
    let text = QAAdoptRun.render(report, json: false)
    #expect(text.contains("build next"), "\(text)")
    #expect(
      text.contains("\"$SG\" build merge \(QARepo.slug) views --session session-1 --json"),
      "\(text)")
  }
}

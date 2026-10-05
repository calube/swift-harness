import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// `qa run --after <task> --before-merge` in a real repository: `main` holds 1 merged task's file,
/// and the screens task's branch, cut before that merge, adds its own.
@Suite("qa run --before-merge")
struct QARunBeforeMergeTests {
  static let screens = "send-ui"
  static let branch = "\(QARepo.slug)/\(screens)"
  /// Passes only where both the merged task's file and the screens task's file exist.
  static let check = "test -f flow.txt && test -f ui.txt || exit 4"

  /// The screens branch adds `ui.txt` (or writes `conflicting` to `app.txt`); `main` then gains
  /// `flow.txt`, merged by the other task the row runs after.
  static func repo(conflicting: String? = nil) async throws -> (repo: QARepo, tip: String) {
    let repo = try await QARepo()
    try await repo.git("switch", "-q", "-c", branch)
    if let conflicting {
      try Data(conflicting.utf8).write(to: repo.root.appending(path: "app.txt"))
    } else {
      try Data("ui\n".utf8).write(to: repo.root.appending(path: "ui.txt"))
    }
    try await repo.git("add", "-A")
    try await repo.git("commit", "-q", "-m", "feat: screens")
    let tip = try await repo.git("rev-parse", "HEAD")
    try await repo.git("switch", "-q", "main")
    try Data("flow\n".utf8).write(to: repo.root.appending(path: "flow.txt"))
    try Data("main\n".utf8).write(to: repo.root.appending(path: "app.txt"))
    try await repo.git("add", "-A")
    try await repo.git("commit", "-q", "-m", "Merge: send flow")
    try repo.plan(
      [validationRow("req-search", .acceptance, check, after: ["send-flow", screens])],
      tasks: ["send-flow": .done, screens: .inProgress])
    return (repo, tip)
  }

  @Test(
    "the row runs where the task's branch is merged into main's tip, passing although neither main nor the branch alone holds both files, and main, its checkout and its worktrees are as they were — catches flows run only after main moved"
  )
  func runsOnTheTrialMerge() async throws {
    let (repo, tip) = try await Self.repo()
    defer { repo.remove() }
    let base = try await repo.git("rev-parse", "main")

    let before = await repo.run(QARunRun.Options(after: Self.screens, beforeMerge: true))
    let onMain = await repo.run(QARunRun.Options(after: Self.screens), suffix: 2)

    #expect(before.rows.map(\.result) == [.pass], "\(before.rows.map(\.message))")
    #expect(before.verdict == .green, "\(before.message)")
    #expect(before.trialMerge == QATrialMerge(branch: Self.branch, tip: tip, base: base))
    #expect(onMain.rows.map(\.result) == [.red])
    #expect(try await repo.git("rev-parse", "main") == base)
    #expect(try await repo.git("status", "--porcelain") == "")
    #expect(!FileManager.default.fileExists(atPath: repo.root.appending(path: "ui.txt").path))
    let worktrees = try await repo.git("worktree", "list", "--porcelain")
    #expect(worktrees.components(separatedBy: "worktree ").count == 2, "\(worktrees)")
    let written = try QAReportJSON.decode(
      Data(contentsOf: try repo.runDirectory(before).appending(path: "qa/report.json")))
    #expect(written.trialMerge == before.trialMerge)
  }

  @Test(
    "a branch that conflicts with main runs no row, reads each ready row unverified naming the conflict, and records the conflicted files — catches a conflicting task stuck behind a run that can't happen"
  )
  func conflictRunsNothing() async throws {
    let (repo, tip) = try await Self.repo(conflicting: "screens\n")
    defer { repo.remove() }
    let base = try await repo.git("rev-parse", "main")

    let report = await repo.run(QARunRun.Options(after: Self.screens, beforeMerge: true))

    #expect(
      report.trialMerge
        == QATrialMerge(branch: Self.branch, tip: tip, base: base, conflicts: ["app.txt"]))
    #expect(report.rows.map(\.result) == [.unverified], "\(report.rows.map(\.message))")
    #expect(report.rows.first?.message.contains("app.txt") == true)
    #expect(try await repo.git("rev-parse", "main") == base)
  }

  @Test(
    "--before-merge without --after, or with --at-base or --final, and --fix without --before-merge, are BLOCKED and run nothing — catches a trial merge of no branch"
  )
  func flagsNeedAfter() async throws {
    let (repo, _) = try await Self.repo()
    defer { repo.remove() }

    let reports = [
      await repo.run(QARunRun.Options(beforeMerge: true)),
      await repo.run(QARunRun.Options(after: Self.screens, atBase: true, beforeMerge: true)),
      await repo.run(QARunRun.Options(final: true, beforeMerge: true)),
      await repo.run(QARunRun.Options(after: Self.screens, fix: true)),
    ]

    #expect(reports.map(\.verdict) == [.blocked, .blocked, .blocked, .blocked])
    #expect(reports.allSatisfy { $0.rows.isEmpty })
  }
}

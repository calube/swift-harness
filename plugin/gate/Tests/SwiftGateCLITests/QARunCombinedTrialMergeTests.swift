import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// `qa run --after <task> --before-merge` with more tasks alongside, in a real repository: 2 task
/// branches cut from `main`, neither merged, and a row that runs after both.
@Suite("qa run --before-merge over every task a row waits on")
struct QARunCombinedTrialMergeTests {
  static let logic = "send-logic"
  static let screens = "send-ui"
  /// Passes only where both tasks' files exist.
  static let check = "test -f logic.txt && test -f ui.txt || exit 4"

  /// Each task's branch adds its own file; with `conflicting`, both write `app.txt`.
  static func repo(conflicting: Bool = false) async throws
    -> (repo: QARepo, logic: String, screens: String)
  {
    let repo = try await QARepo()
    var tips: [String] = []
    for (task, file) in [(logic, "logic.txt"), (screens, "ui.txt")] {
      try await repo.git("switch", "-q", "-c", "\(QARepo.slug)/\(task)", "main")
      let path = conflicting ? "app.txt" : file
      try Data("\(task)\n".utf8).write(to: repo.root.appending(path: path))
      try await repo.git("add", "-A")
      try await repo.git("commit", "-q", "-m", "feat: \(task)")
      tips.append(try await repo.git("rev-parse", "HEAD"))
    }
    try await repo.git("switch", "-q", "main")
    try repo.plan(
      [validationRow("req-send", .acceptance, check, after: [logic, screens])],
      tasks: [logic: .inProgress, screens: .inProgress])
    return (repo, tips[0], tips[1])
  }

  @Test(
    "the row runs on main with both branches merged before either lands, passing where a run of either branch alone reads it waiting, and the report names both tips — catches rows held until the last of their tasks merges"
  )
  func bothBranchesMergeInOneTree() async throws {
    let (repo, logic, screens) = try await Self.repo()
    defer { repo.remove() }
    let base = try await repo.git("rev-parse", "main")

    let alone = await repo.run(
      QARunRun.Options(after: Self.logic, beforeMerge: true), suffix: 1)
    let both = await repo.run(
      QARunRun.Options(after: Self.logic, beforeMerge: true, alongside: [Self.screens]),
      suffix: 2)

    #expect(alone.rows.map(\.result) == [.waiting])
    #expect(both.rows.map(\.result) == [.pass], "\(both.rows.map(\.message)) \(both.message)")
    #expect(both.verdict == .green)
    #expect(
      both.trialMerge
        == QATrialMerge(
          branch: "\(QARepo.slug)/\(Self.logic)", tip: logic, base: base,
          alongside: [
            QATrialMerge.Branch(
              task: Self.screens, branch: "\(QARepo.slug)/\(Self.screens)", tip: screens)
          ]))
    #expect(try await repo.git("rev-parse", "main") == base)
    #expect(try await repo.git("status", "--porcelain") == "")
    let written = try QAReportJSON.decode(
      Data(contentsOf: try repo.runDirectory(both).appending(path: "qa/report.json")))
    #expect(written.trialMerge == both.trialMerge)
  }

  @Test(
    "branches that conflict with each other run no row and name the file — catches a combined run that reads a broken merge as checked"
  )
  func conflictBetweenBranchesRunsNothing() async throws {
    let (repo, _, _) = try await Self.repo(conflicting: true)
    defer { repo.remove() }

    let report = await repo.run(
      QARunRun.Options(after: Self.logic, beforeMerge: true, alongside: [Self.screens]))

    #expect(report.trialMerge?.conflicts == ["app.txt"], "\(report.message)")
    #expect(report.rows.map(\.result) == [.unverified])
    #expect(report.rows.first?.message.contains("app.txt") == true)
  }

  @Test(
    "a fixer's run naming a task alongside that has since merged, its branch deleted, takes that task as already on main: the row passes on the fix branch merged into main, and a note names the merged task — catches the price-tracker fixer's run BLOCKED because its fix run still named the merged detail task"
  )
  func mergedTaskAlongsideIsOnMain() async throws {
    let (repo, _, _) = try await Self.repo()
    defer { repo.remove() }
    let fix = "\(QARepo.slug)/fix-\(Self.logic)"
    try await repo.git("branch", fix, "\(QARepo.slug)/\(Self.logic)")
    try await repo.git("merge", "-q", "--no-ff", "-m", "Merge", "\(QARepo.slug)/\(Self.screens)")
    try await repo.git("branch", "-D", "\(QARepo.slug)/\(Self.screens)")
    try repo.plan(
      [validationRow("req-send", .acceptance, Self.check, after: [Self.logic, Self.screens])],
      tasks: [Self.logic: .inProgress, Self.screens: .done])
    let base = try await repo.git("rev-parse", "main")

    let report = await repo.run(
      QARunRun.Options(
        after: Self.logic, beforeMerge: true, fix: true, alongside: [Self.screens]))

    #expect(report.verdict == .green, "\(report.message)")
    #expect(report.rows.map(\.result) == [.pass], "\(report.rows.map(\.message))")
    #expect(report.trialMerge?.branch == fix)
    #expect(report.trialMerge?.base == base)
    #expect(report.trialMerge?.alongside == [])
    #expect(report.notes.contains { $0.contains(Self.screens) }, "\(report.notes)")
  }

  @Test(
    "tasks alongside without --before-merge, or naming no ledger task, are BLOCKED and run nothing — catches a combined run with no trial merge"
  )
  func alongsideNeedsBeforeMerge() async throws {
    let (repo, _, _) = try await Self.repo()
    defer { repo.remove() }

    let reports = [
      await repo.run(QARunRun.Options(after: Self.logic, alongside: [Self.screens])),
      await repo.run(
        QARunRun.Options(after: Self.logic, beforeMerge: true, alongside: ["no-such-task"])),
    ]

    #expect(reports.map(\.verdict) == [.blocked, .blocked], "\(reports.map(\.message))")
    #expect(reports.allSatisfy { $0.rows.isEmpty })
  }
}

/// What `qa run` prints, over the at-base report a captured trial's orchestrator kept: a reader
/// that cuts the output to its last lines still has the run and its report file.
@Suite("qa run: the summary line")
struct QARunSummaryLineTests {
  static func report() throws -> QAReport {
    try QAReportJSON.decode(try Fixture.data("BrownfieldTrial/send-money-4-qa-at-base.json"))
  }

  @Test(
    "the text output's last line, and the JSON's last member, name the verdict, the run id and the report file, and the JSON still decodes — catches a run repeated because a tail of its output lost which run it was"
  )
  func lastLineNamesTheRunAndItsFile() throws {
    let report = try Self.report()
    let runID = try #require(report.runID)
    let file = "/repo/.harness/runs/\(runID)/qa/report.json"
    let line = "qa run: \(report.verdict.rawValue) \(report.message); run \(runID), report \(file)"

    let text = QARunRun.render(report, json: false, reportFile: file)
    let json = QARunRun.render(report, json: true, reportFile: file)

    #expect(text.split(separator: "\n").last.map(String.init) == line, "\(text)")
    #expect(QARunRun.summary(report, reportFile: file) == line)
    let jsonLines = json.split(separator: "\n").map(String.init)
    #expect(jsonLines.suffix(2) == ["  \"summary\" : \"\(line)\"", "}"], "\(jsonLines.suffix(3))")
    let decoded = try QAReportJSON.decode(Data(json.utf8))
    #expect(decoded == report)
  }
}

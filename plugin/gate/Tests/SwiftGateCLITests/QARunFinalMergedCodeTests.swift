import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// `qa run --final` over the sixth send-money trial's plan state: its table, its end-of-run ledger
/// with account-client `abandoned`, its build events, and the flows adopted by the end. The
/// repository rebuilds the trial's branch shape: amount-feature's fix branch took account-client's
/// branch in, and the plan branch merged that fix after the cutoff abandoned account-client.
@Suite("qa run --final: rows follow the merged code")
struct QARunFinalMergedCodeTests {
  static let fixtures = "BrownfieldTrial"
  static let buildRun = "20261005T093334Z-df9989d6"
  static let fixerRun = "20261005T095459Z-322909d3"
  static let flows = [
    "contact-search", "keypad", "continue-rule", "send-success", "send-failure",
  ]

  /// The captured plan state, and the trial's branches: with `carried`, the fix branch merged
  /// into `main` holds account-client's commit; without it, account-client's branch stays off.
  static func repo(carried: Bool) async throws -> QARepo {
    let repo = try await QARepo()
    let plan = repo.planDirectory
    try Fixture.data("\(fixtures)/send-money-6-validation.json")
      .write(to: plan.appending(path: ValidationTable.fileName))
    try Fixture.data("\(fixtures)/send-money-6-ledger.json")
      .write(to: plan.appending(path: "ledger.json"))
    for flow in flows {
      try Fixture.data("\(fixtures)/send-money-6-qa/\(flow).flow.json")
        .write(to: plan.appending(path: "qa/\(flow).flow.json"))
    }
    let build = plan.appending(path: "build/\(buildRun)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
    try Fixture.data("\(fixtures)/send-money-6-build-events.jsonl")
      .write(to: build.appending(path: "events.jsonl"))

    let slug = QARepo.slug
    try await repo.git("switch", "-q", "-c", "\(slug)/account-client")
    try Data("account\n".utf8).write(to: repo.root.appending(path: "AccountClient.swift"))
    try await repo.git("add", "-A")
    try await repo.git("commit", "-q", "-m", "account backend")
    try await repo.git("switch", "-q", "main")
    try await repo.git("switch", "-q", "-c", "\(slug)/fix-amount-feature")
    try Data("amount\n".utf8).write(to: repo.root.appending(path: "Amount.swift"))
    try await repo.git("add", "-A")
    try await repo.git("commit", "-q", "-m", "amount balance caption")
    if carried {
      try await repo.git(
        "merge", "-q", "--no-ff", "-m", "Merge \(slug)/account-client", "\(slug)/account-client")
    }
    try await repo.git("switch", "-q", "main")
    try await repo.git(
      "merge", "-q", "--no-ff", "-m", "Merge: amount fix", "\(slug)/fix-amount-feature")
    return repo
  }

  /// Writes the fixer's merged-tree record into the run store, its `tree` set to `tree`.
  static func fixerRecord(in repo: QARepo, tree: String) throws {
    let captured = try QAMergedTreeRun.decode(
      Fixture.data("\(fixtures)/send-money-6-merged-tree-run-fixer.json"))
    let directory = try RunStore(worktreeRoot: repo.root).runDirectory(for: captured.run.runID)
      .appending(path: QAReport.directory, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try QAMergedTreeRun(tree: tree, run: captured.run).encoded()
      .write(to: directory.appending(path: QAMergedTreeRun.fileName))
  }

  @Test(
    "with account-client abandoned in the ledger but its commit in the final commit through the fix it rode in on, no row reads abandoned, and the 4 rows the fixer's run passed on the same tree are credited from it while the repaired row runs again — catches 0 of 9 verified on a tree that passed 4 of 5 with video"
  )
  func carriedTaskRowsRunAndSameTreePassesCount() async throws {
    let repo = try await Self.repo(carried: true)
    defer { repo.remove() }
    try Self.fixerRecord(in: repo, tree: try await repo.git("rev-parse", "HEAD^{tree}"))

    let report = await repo.run(QARunRun.Options(final: true))

    #expect(!report.rows.contains { $0.result == .abandoned }, "\(report.rows.map(\.message))")
    let credited = report.rows.filter { (2...5).contains($0.row) }
    #expect(credited.map(\.result) == [.pass, .pass, .pass, .pass], "\(report.message)")
    #expect(credited.allSatisfy { $0.reusedFrom == Self.fixerRun }, "\(credited)")
    let search = try #require(report.rows.first { $0.row == 1 })
    #expect(search.reusedFrom == nil)
    #expect(!search.message.contains("abandoned"), "\(search.message)")
    #expect(
      report.notes.contains { $0.contains("account-client") && $0.contains("abandoned") },
      "\(report.notes)")
  }

  @Test(
    "with account-client's commit not in the final commit, its rows still read abandoned and no earlier run is credited — catches rows run or credited over code that never landed"
  )
  func uncarriedTaskRowsStayAbandoned() async throws {
    let repo = try await Self.repo(carried: false)
    defer { repo.remove() }
    try Self.fixerRecord(in: repo, tree: String(repeating: "0", count: 40))

    let report = await repo.run(QARunRun.Options(final: true))

    #expect(report.rows.map(\.result) == Array(repeating: .abandoned, count: 5), "\(report.message)")
    #expect(report.rows.allSatisfy { $0.reusedFrom == nil })
  }

  @Test(
    "a row the fixer's run passed on this tree, after an earlier run read the same flow file red and a fixer's flow row line called the app correct there, is credited as flaky and unverified, while the other credited rows pass — catches a final report that shows a race won once as a pass"
  )
  func racyRowCreditedAsFlaky() async throws {
    let repo = try await Self.repo(carried: true)
    defer { repo.remove() }
    try Self.fixerRecord(in: repo, tree: try await repo.git("rev-parse", "HEAD^{tree}"))
    // The run before the fixer's, with the keypad row red on the same flow file.
    let fixer = try QAMergedTreeRun.decode(
      Fixture.data("\(Self.fixtures)/send-money-6-merged-tree-run-fixer.json"))
    let redRun = "20261005T094500Z-0000beef"
    let red = QAMergedTreeRun(
      tree: String(repeating: "1", count: 40),
      run: QAAtBaseRun(
        runID: redRun, preparedBy: fixer.run.preparedBy, commit: fixer.run.commit,
        rows: fixer.run.rows.map { row in
          guard row.requirement == "req-keypad-input" else { return row }
          return QAAtBaseRun.Row(
            requirement: row.requirement, layer: row.layer, check: row.check, digest: row.digest,
            result: .red, message: "step 4 `wait` failed", exitStatus: nil,
            milliseconds: row.milliseconds)
        }))
    let directory = try RunStore(worktreeRoot: repo.root).runDirectory(for: redRun)
      .appending(path: QAReport.directory, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try red.encoded().write(to: directory.appending(path: QAMergedTreeRun.fileName))
    let check = BuildEvent.returnCheck(
      .init(
        task: "amount-feature", fix: true, verdict: .green, commit: nil, checkID: "fix-check",
        rules: [], at: Date(timeIntervalSince1970: 1_791_190_000), outcome: .gateRed,
        flowRows: [
          FlowRowVerdict(requirement: "req-keypad-input", runs: [redRun], appShownCorrect: true)
        ]))
    let events = repo.planDirectory.appending(path: "build/\(Self.buildRun)/events.jsonl")
    let handle = try FileHandle(forWritingTo: events)
    try handle.seekToEnd()
    try handle.write(contentsOf: try BuildEventJSON.encodeLine(check))
    try handle.close()

    let report = await repo.run(QARunRun.Options(final: true))

    let keypad = try #require(report.rows.first { $0.requirement == "req-keypad-input" })
    #expect(keypad.result == .unverified, "\(keypad.message)")
    #expect(keypad.message.hasPrefix("flaky: "), "\(keypad.message)")
    #expect(keypad.message.contains("qa run \(redRun)"), "\(keypad.message)")
    let others = report.rows.filter { (3...5).contains($0.row) }
    #expect(others.map(\.result) == [.pass, .pass, .pass], "\(report.rows.map(\.message))")
  }
}

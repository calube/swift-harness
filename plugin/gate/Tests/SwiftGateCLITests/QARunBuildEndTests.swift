import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// `qa run` over a captured trial's plan state: its table, its ledger at the end, with the task
/// that the flow and state rows run after marked `abandoned`, and its build run's events, where
/// that task's merge landed GREEN and a `final` gate followed.
@Suite("qa run: a plan whose build has ended")
struct QARunBuildEndTests {
  static let directory = "QA/aidoku-validation-3"
  static let buildRun = "20261004T234410Z-daacb3fb"
  static let setting = "confirm-downloads-setting"

  /// Writes the captured table and ledger into the plan's state, and the captured build events
  /// whose lines `keep` accepts.
  static func repo(keeping keep: (String) -> Bool = { _ in true }) async throws -> QARepo {
    let repo = try await QARepo()
    let plan = repo.planDirectory
    try Fixture.data("\(directory)/validation.json")
      .write(to: plan.appending(path: ValidationTable.fileName))
    try Fixture.data("\(directory)/ledger.json").write(to: plan.appending(path: "ledger.json"))
    let build = plan.appending(path: "build/\(buildRun)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
    let lines = try Fixture.text("\(directory)/build-events.jsonl")
      .split(separator: "\n").map(String.init).filter(keep)
    try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: build.appending(path: "events.jsonl"))
    return repo
  }

  static func isSettingMerge(_ line: String) -> Bool {
    line.contains("\"kind\":\"merge\"") && line.contains("\"task\":\"\(setting)\"")
  }

  static func isFinalGate(_ line: String) -> Bool {
    line.contains("\"gate\":\"final\"")
  }

  @Test(
    "after the final gate, rows whose task merged by the build's events run although the ledger reads it abandoned, and the unverified rows make the run RED — catches a final GREEN with rows waiting on merged code"
  )
  func mergedByEventsRunsAtEnd() async throws {
    let repo = try await Self.repo()
    defer { repo.remove() }

    let report = await repo.run(QARunRun.Options())

    #expect(report.rows.allSatisfy { $0.result != .waiting }, "\(report.rows.map(\.message))")
    #expect(report.settled)
    #expect(report.verdict == .red, "\(report.message)")
    #expect(
      report.findings.allSatisfy {
        $0.ruleID == QAReport.checkUnverifiedRuleID && $0.severity.failsGate
      })
  }

  @Test(
    "after the final gate, rows whose task was abandoned with no merge read abandoned and the run is RED — catches a GREEN final verdict over rows that never ran"
  )
  func abandonedAtEnd() async throws {
    let repo = try await Self.repo { !Self.isSettingMerge($0) }
    defer { repo.remove() }

    let report = await repo.run(QARunRun.Options())

    let settingRows = report.rows.filter { $0.runsAfter == [Self.setting] }
    #expect(settingRows.map(\.result) == [.abandoned, .abandoned, .abandoned])
    #expect(report.verdict == .red, "\(report.message)")
    #expect(report.message.contains("3 abandoned"), "\(report.message)")
  }

  @Test(
    "before the final gate, rows whose task hasn't merged read waiting and the run stays GREEN — catches a merge-time run gated on rows whose code isn't in yet"
  )
  func waitingDuringMerges() async throws {
    let repo = try await Self.repo { !Self.isSettingMerge($0) && !Self.isFinalGate($0) }
    defer { repo.remove() }

    let report = await repo.run(QARunRun.Options())

    let settingRows = report.rows.filter { $0.runsAfter == [Self.setting] }
    #expect(settingRows.map(\.result) == [.waiting, .waiting, .waiting])
    #expect(!report.settled)
    #expect(report.verdict == .green, "\(report.message)")
  }
}

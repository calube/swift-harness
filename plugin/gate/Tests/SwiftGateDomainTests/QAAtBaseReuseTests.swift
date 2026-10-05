import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// Which rows an orchestrator's `qa run --at-base` takes from a validation worker's prepared run,
/// from a captured trial whose at-base run drove both flows on a device a second time after the
/// worker had already proved them red.
@Suite("qa run --at-base: reusing a prepared run")
struct QAAtBaseReuseTests {
  static let directory = "QA/aidoku-validation-3"
  static let worker = "spec-validation"

  static func table() throws -> ValidationTable {
    try ValidationTableJSON.decode(try Fixture.data("\(directory)/validation.json"))
  }

  static func atBase() throws -> QAReport {
    try QAReportJSON.decode(try Fixture.data("\(directory)/at-base-report.json"))
  }

  /// The captured checks under plan state's `qa/`, by their `check`.
  static func files() throws -> [String: Data] {
    [
      "qa/confirm-large-downloads-toggle.flow.json":
        try Fixture.data("BrownfieldTrial/aidoku-validation-3-toggle.flow.json"),
      "qa/confirm-large-downloads-store.flow.json":
        try Fixture.data("BrownfieldTrial/aidoku-validation-3-store.flow.json"),
      "qa/confirm-large-downloads-store.state.sh":
        try Fixture.data("\(directory)/store.state.sh"),
    ]
  }

  static func digests(_ table: ValidationTable, files: [String: Data]) -> [Int: String] {
    Dictionary(
      uniqueKeysWithValues: table.rows.enumerated().map { index, row in
        (
          index + 1,
          QAAtBaseRun.digest(layer: row.layer, check: row.check, file: files[row.check])
        )
      })
  }

  /// What the worker's `--prepared-by` run would have recorded: the captured at-base result of
  /// each row it writes, with the digest of the check it ran.
  static func record() throws -> QAAtBaseRun {
    let table = try table()
    let report = try atBase()
    let written = Set(
      table.rows.enumerated().filter { $0.element.writer == worker }.map { $0.offset + 1 })
    return QAAtBaseRun(
      runID: "20261004T234900Z-0000beef", preparedBy: worker, commit: report.commit,
      rows: report.rows.filter { written.contains($0.row) },
      digests: digests(table, files: try files()))
  }

  static func plan() throws -> QARunPlan {
    QARunPlan.make(table: try table(), merged: nil, after: nil)
  }

  @Test(
    "the at-base run takes each worker row whose check is byte-identical, citing the worker's run and its reason, and runs only the acceptance row another task writes — catches both flows driven on a device twice"
  )
  func reusesUnchangedRows() throws {
    let record = try Self.record()

    let reuse = record.reuse(
      in: try Self.plan(), digests: Self.digests(try Self.table(), files: try Self.files()))

    #expect(reuse.outcomes.keys.sorted() == [1, 2, 3], "\(reuse.reasons)")
    #expect(reuse.outcomes.values.allSatisfy { $0.result == .red })
    #expect(reuse.outcomes.values.allSatisfy { $0.reusedFrom == record.runID })
    #expect(
      reuse.outcomes[3]?.message.contains("Downloads.confirmLargeDownloads) does not exist")
        == true, "\(reuse.outcomes[3]?.message ?? "")")
    #expect(reuse.outcomes[3]?.exitStatus == 1)
    #expect(reuse.reasons.keys.sorted() == [4])
    #expect(reuse.reasons[4]?.contains(record.runID) == true, "\(reuse.reasons)")
  }

  @Test(
    "a flow whose file changed by 1 byte runs again with the state row that reads its device, and the other requirement's flow stays reused — catches a stale red reused for an edited check, or a state row reused without its device"
  )
  func changedFlowRunsWithItsState() throws {
    var files = try Self.files()
    files["qa/confirm-large-downloads-store.flow.json"]?.append(UInt8(ascii: "\n"))

    let reuse = try Self.record().reuse(
      in: try Self.plan(), digests: Self.digests(try Self.table(), files: files))

    #expect(reuse.outcomes.keys.sorted() == [1], "\(reuse.reasons)")
    #expect(reuse.reasons[2]?.contains("changed") == true, "\(reuse.reasons)")
    #expect(reuse.reasons[3]?.contains("1 device") == true, "\(reuse.reasons)")
  }

  @Test(
    "a changed state script takes its unchanged flow with it, since only a run of that flow brings the device up — catches a state row run with no device"
  )
  func changedStateRunsItsFlow() throws {
    var files = try Self.files()
    files["qa/confirm-large-downloads-store.state.sh"] = Data("exit 1\n".utf8)

    let reuse = try Self.record().reuse(
      in: try Self.plan(), digests: Self.digests(try Self.table(), files: files))

    #expect(reuse.outcomes.keys.sorted() == [1], "\(reuse.reasons)")
    #expect(reuse.reasons[3]?.contains("changed") == true, "\(reuse.reasons)")
    #expect(reuse.reasons[2]?.contains("1 device") == true, "\(reuse.reasons)")
  }

  @Test(
    "a row the worker's run left unverified runs again, and a row the run never held is not taken from another row's record — catches a row with no red run counted as proven"
  )
  func unverifiedRunsAgain() throws {
    let table = try Self.table()
    let report = try Self.atBase()
    let rows = report.rows.filter { $0.row == 1 }.map { row in
      QARow(
        row: row.row, requirement: row.requirement, layer: row.layer, check: row.check,
        runsAfter: row.runsAfter, result: .unverified, message: "not run: no device")
    }
    let record = QAAtBaseRun(
      runID: "20261004T234900Z-0000beef", preparedBy: Self.worker, commit: report.commit,
      rows: rows, digests: Self.digests(table, files: try Self.files()))

    let reuse = record.reuse(
      in: try Self.plan(), digests: Self.digests(table, files: try Self.files()))

    #expect(reuse.outcomes.isEmpty, "\(reuse.outcomes)")
    #expect(reuse.reasons[1]?.contains("unverified") == true, "\(reuse.reasons)")
    #expect(reuse.reasons.keys.sorted() == [1, 2, 3, 4])
  }
}

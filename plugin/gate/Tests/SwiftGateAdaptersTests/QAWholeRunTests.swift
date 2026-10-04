import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// Which of a checkout's `qa run` reports the run report reads, from a captured trial's reports.
@Suite("qa files: the newest whole qa run")
struct QAWholeRunTests {
  /// A runs folder holding each captured report under its own run id.
  static func runs(_ names: [String]) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-qa-runs-\(UUID().uuidString)", directoryHint: .isDirectory)
    for name in names {
      let data = try Fixture.data("QA/aidoku-validation/\(name)")
      let runID = try #require(try QAReportJSON.decode(data).runID)
      let qa = directory.appending(path: "\(runID)/qa", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: qa, withIntermediateDirectories: true)
      try data.write(to: qa.appending(path: QAReport.fileName))
    }
    return directory
  }

  @Test(
    "the newest report over every row wins over an --after run and an at-base run, and with only those, or another plan's runs, there is none — catches a run report that reads a run of no rows, or a red-run proof, as the plan's validation"
  )
  func picksTheWholeRun() throws {
    let all = try Self.runs(["at-base-report.json", "after-report.json", "final-report.json"])
    defer { try? FileManager.default.removeItem(at: all) }
    let partial = try Self.runs(["at-base-report.json", "after-report.json"])
    defer { try? FileManager.default.removeItem(at: partial) }

    guard case .read(let report) = QAFiles.newestWholeRun(plan: "spec", runsDirectory: all) else {
      Issue.record("no whole run read")
      return
    }
    #expect(report.runID == "20261004T213430Z-5250c2ac")
    #expect(
      QAFiles.newestWholeRun(plan: "spec", runsDirectory: partial)
        == .missing(path: partial.path))
    #expect(QAFiles.newestWholeRun(plan: "other", runsDirectory: all) == .missing(path: all.path))
  }
}

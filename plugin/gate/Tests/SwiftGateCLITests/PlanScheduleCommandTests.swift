import Foundation
import SwiftGateDomain
import Testing

@testable import SwiftGateCLI

@Suite("swiftgate plan-schedule")
struct PlanScheduleCommandTests {
  @Test(
    "a ledger with a repeated task id answers BLOCKED with exit 2 naming the id — catches a trap on a hand-edited ledger"
  )
  func duplicateTaskIDBlocks() async {
    await #expect(processExitsWith: .success) {
      let directory = FileManager.default.temporaryDirectory
        .appending(
          path: "swiftgate-plan-schedule-\(UUID().uuidString)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: directory) }
      func task(_ writeSet: String) -> LedgerTask {
        LedgerTask(
          id: "queue-core", deps: [], writeSet: [writeSet], gate: .fast, tests: [], covers: [],
          estLines: 100, status: .pending, worktree: "../queue-core")
      }
      let ledger = Ledger(
        schemaVersion: 1, resume: "planned", maxParallel: 3, tasks: [task("A/"), task("B/")],
        waves: [["queue-core"]])
      let path = directory.appending(path: "ledger.json").path
      try LedgerJSON.encode(ledger).write(to: URL(filePath: path))

      let report = PlanScheduleRun.run(ledgerPath: path)
      let json = PlanScheduleReport.render(report, format: .json)
      let keys = try #require(
        try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])

      #expect(report.verdict == .blocked)
      #expect(report.verdict.exitCode == 2)
      #expect(keys["duplicateTaskIDs"] as? [String] == ["queue-core"])
      #expect(keys["waves"] == nil)
      #expect(report.message.contains("queue-core"))
    }
  }
}

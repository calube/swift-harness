import Foundation
import SwiftGateDomain
import Testing

@Suite("Ledger progress")
struct LedgerProgressTests {
  /// An encoded ledger with 1 done and 1 pending task, as a JSON object to edit.
  static func encodedLedger() throws -> [String: Any] {
    let ledger = Ledger(
      schemaVersion: 1, resume: "", maxParallel: 2,
      tasks: [
        LedgerBuildStatesTests.task(status: .done),
        LedgerTask(
          id: "list-ui", deps: [], writeSet: ["b/"], gate: .push, tests: [], covers: [],
          estLines: 10, status: .pending, worktree: "../l"),
      ], waves: [["offline-queue-core-reducer", "list-ui"]])
    return try #require(
      try JSONSerialization.jsonObject(with: LedgerJSON.encode(ledger)) as? [String: Any])
  }

  @Test(
    "progress reads each task's merged status from a ledger with no waves key, while the full ledger refuses it — catches a reader that needs the schedule to say what merged"
  )
  func noWaves() throws {
    var object = try Self.encodedLedger()
    object.removeValue(forKey: "waves")
    let data = try JSONSerialization.data(withJSONObject: object)

    let progress = try LedgerProgressJSON.decode(data)

    #expect(progress.merged == ["offline-queue-core-reducer"])
    #expect(progress.contains("list-ui") && !progress.contains("list-iu"))
    #expect(throws: (any Error).self) { try LedgerJSON.decode(data) }
  }
}

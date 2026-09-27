import Foundation
import SwiftGateAdapters
import Testing

/// A plan directory holding one build run's `returns/`, laid out as the build skill stores them.
private struct ReturnsScenario {
  static let runID = "20260927T090000Z-0a1b2c3d"

  let root = FileManager.default.temporaryDirectory
    .appending(path: "swiftgate-task-return-\(UUID().uuidString)", directoryHint: .isDirectory)
  let ledgerPath = "plans/2026-09-26-search/ledger.json"

  func write(task: String, _ text: String) throws {
    let directory = root.appending(
      path: "plans/2026-09-26-search/build/\(Self.runID)/returns", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(text.utf8).write(to: directory.appending(path: "\(task).json"))
  }

  func notes(_ task: String) -> Result<String, ContextPackTaskReturn.Failure> {
    ContextPackTaskReturn.notes(
      forTask: task, buildRun: Self.runID, ledgerPath: ledgerPath, root: root)
  }

  func remove() { try? FileManager.default.removeItem(at: root) }

  static func fullReturn(task: String, extra: String = "") -> String {
    """
    {"task": "\(task)", "outcome": "ready-to-merge", "commits": ["3f2a91c"],
     "gate": {"tier": "push", "verdict": "GREEN", "runId": "20260927T085900Z-00aa11bb"},
     "review": {"mode": "gate", "findings": []}, "testsAdded": ["test-fetch-loads"],
     "notes": "Fetcher.load() returns [Item]", "designConflict": null,
     "surfaceCommit": null\(extra)}
    """
  }
}

@Suite("dependency notes read from a stored task return")
struct ContextPackTaskReturnTests {
  @Test(
    "a stored task return's notes come back verbatim — catches the dependency-notes reader rejecting the shape check-return passes"
  )
  func fullReturnYieldsNotes() throws {
    let scenario = ReturnsScenario()
    defer { scenario.remove() }
    try scenario.write(task: "fetch", ReturnsScenario.fullReturn(task: "fetch"))

    #expect(scenario.notes("fetch") == .success("Fetcher.load() returns [Item]"))
  }

  @Test(
    "a return that isn't a whole task return is malformed: bare task and notes, an unknown key, or an unknown outcome — catches a pack quoting notes from a return check-return never passed",
    arguments: [
      #"{"task": "fetch", "notes": "Fetcher.load() returns [Item]"}"#,
      ReturnsScenario.fullReturn(task: "fetch", extra: #", "verified": true"#),
      ReturnsScenario.fullReturn(task: "fetch").replacingOccurrences(
        of: "ready-to-merge", with: "mostly-done"),
    ])
  func partialReturnIsMalformed(text: String) throws {
    let scenario = ReturnsScenario()
    defer { scenario.remove() }
    try scenario.write(task: "fetch", text)

    #expect(
      scenario.notes("fetch")
        == .failure(
          .malformed(
            path: "plans/2026-09-26-search/build/\(ReturnsScenario.runID)/returns/fetch.json")))
  }

  @Test(
    "a return naming another task is malformed — catches one task's notes filed under a dependency's name"
  )
  func mismatchedTaskIsMalformed() throws {
    let scenario = ReturnsScenario()
    defer { scenario.remove() }
    try scenario.write(task: "fetch", ReturnsScenario.fullReturn(task: "render"))

    guard case .failure(.malformed) = scenario.notes("fetch") else {
      Issue.record("a return for `render` stored as `fetch` was accepted")
      return
    }
  }
}

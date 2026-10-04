import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// Seeds a temp repository from the build run captured with 2 tasks in flight at once, so nothing
/// here reads or writes this checkout's own stores or plan state.
@Suite("run view reader, 2 tasks at once")
struct RunViewReaderConcurrentTests {
  static let captured = Fixture.gateDirectory.appending(
    path: "Tests/Fixtures/RunView/build-run-2", directoryHint: .isDirectory)
  static let buildRun = "20261004T095203Z-7053bb32"
  static let plan = "2026-10-04-counter-reset-and-floor"

  struct Seeded {
    let parent: URL
    let reader: RunViewReader
    let runEvents: URL
    let events: URL
  }

  static func lines(_ path: String) throws -> [String] {
    try String(contentsOf: captured.appending(path: path), encoding: .utf8)
      .split(separator: "\n").map(String.init)
  }

  static func write(_ lines: [String], to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: url)
  }

  static func seed() throws -> Seeded {
    let fileManager = FileManager.default
    let parent = fileManager.temporaryDirectory.appending(
      path: "run-view-reader-concurrent-\(UUID().uuidString)", directoryHint: .isDirectory)
    let checkout = parent.appending(path: "app", directoryHint: .isDirectory)
    let common = checkout.appending(path: ".git", directoryHint: .isDirectory)
    let planDirectory = common.appending(
      path: "swift-harness/plans/\(plan)", directoryHint: .isDirectory)
    let runDirectory = planDirectory.appending(
      path: "build/\(buildRun)", directoryHint: .isDirectory)
    try fileManager.createDirectory(
      at: runDirectory.appending(path: "returns"), withIntermediateDirectories: true)
    try fileManager.createDirectory(
      at: checkout.appending(path: ".harness"), withIntermediateDirectories: true)
    try Data().write(to: checkout.appending(path: ".swiftgate.toml"))
    let copies: [(String, URL)] = [
      ("ledger.json", planDirectory.appending(path: "ledger.json")),
      ("plan.json", planDirectory.appending(path: "plan.json")),
      ("plan.md", planDirectory.appending(path: "spec-page.md")),
      ("run.json", runDirectory.appending(path: "run.json")),
      ("ledger-events.jsonl", runDirectory.appending(path: "events.jsonl")),
      ("events", checkout.appending(path: ".harness/events", directoryHint: .isDirectory)),
    ]
    for (name, target) in copies {
      try fileManager.copyItem(at: captured.appending(path: name), to: target)
    }
    for name in try fileManager.contentsOfDirectory(
      atPath: captured.appending(path: "returns").path)
    {
      try fileManager.copyItem(
        at: captured.appending(path: "returns/\(name)"),
        to: runDirectory.appending(path: "returns/\(name)"))
    }
    return Seeded(
      parent: parent, reader: RunViewReader(commonDirectory: common, stateRoot: .tree(checkout)),
      runEvents: runDirectory.appending(path: "events.jsonl"),
      events: checkout.appending(path: ".harness/events", directoryHint: .isDirectory))
  }

  @Test(
    "the fixer's gate runs between a task's undo and its re-merge read with that task while another task is in progress — catches merge-time fixer gates dropped from the report when 2 tasks overlap"
  )
  func keepsFixerGatesOfOverlappingTasks() throws {
    let seeded = try Self.seed()
    defer { try? FileManager.default.removeItem(at: seeded.parent) }

    let input = try seeded.reader.read(buildRun: Self.buildRun)
    #expect(input.damage.isEmpty, "\(input.damage)")
    // The fixer's `snapshots record` and `check push`, from its imported store; both ran between
    // the undo of `counter-ui-reset-button`'s merge and its re-merge, while
    // `counter-core-reset-and-decrement-floor` was still in progress.
    let fixerRuns = ["20261004T095831Z-84a5238e", "20261004T100055Z-d10691b2"]
    for runID in fixerRuns {
      #expect(input.workerGateRuns[runID] == .some("counter-ui-reset-button"), "\(runID)")
      #expect(
        input.events.contains { $0.kind == .gateRun && $0.runID == runID }, "\(runID)")
    }
    let view = RunViewBuilder.build(input)
    for runID in fixerRuns {
      #expect(
        view.spans.contains {
          $0.id == "gate:\(runID)" && $0.parent == "task:counter-ui-reset-button"
        }, "\(runID)")
    }
  }

  @Test(
    "a fix window with no re-merge closes when its task is done, so a later run goes to the task still in progress — catches an undone task that never re-merged claiming every later gate run"
  )
  func fixWindowClosesWithItsTask() throws {
    let seeded = try Self.seed()
    defer { try? FileManager.default.removeItem(at: seeded.parent) }
    let remerge = "\"at\":\"2026-10-04T10:04:18Z\""
    let log = try Self.lines("ledger-events.jsonl")
    #expect(log.filter { $0.contains(remerge) && $0.contains("\"kind\":\"merge\"") }.count == 1)
    try Self.write(log.filter { !$0.contains(remerge) }, to: seeded.runEvents)

    let store = "events/imported/6a980b74-d6c4-4ad7-be54-d1054cb4fe14/gate.jsonl"
    let push = try #require(
      try Self.lines(store).first { $0.contains("\"gate.run\"") && $0.contains("check push") })
    let object = try JSONSerialization.jsonObject(with: Data(push.utf8)) as? [String: Any]
    let eventID = try #require(object?["eventID"] as? String)
    let late =
      push
      .replacingOccurrences(of: "20261004T100055Z-d10691b2", with: "20261004T100630Z-0badf00d")
      .replacingOccurrences(of: "2026-10-04T10:03:50.492Z", with: "2026-10-04T10:07:00.000Z")
      .replacingOccurrences(of: eventID, with: UUID().uuidString)
    try Self.write([late], to: seeded.events.appending(path: "imported/late/gate.jsonl"))

    let input = try seeded.reader.read(buildRun: Self.buildRun)
    #expect(input.damage.isEmpty, "\(input.damage)")
    #expect(input.workerGateRuns["20261004T100055Z-d10691b2"] == .some("counter-ui-reset-button"))
    #expect(
      input.workerGateRuns["20261004T100630Z-0badf00d"]
        == .some("counter-core-reset-and-decrement-floor"))
  }
}

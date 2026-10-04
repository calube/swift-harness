import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import Testing

@testable import SwiftGateCLI

@Suite("gc --events: sealed segments past their age, by their index's last time")
struct GCEventsTests {
  static let day: TimeInterval = 86_400
  static let now = Date(timeIntervalSince1970: 1_790_000_000)

  static func event(_ id: String, daysAgo: Double) -> HarnessEvent {
    HarnessEvent(
      eventID: id, time: now.addingTimeInterval(-daysAgo * day),
      source: HarnessEventSource(route: .judgeTests),
      payload: .judgeDecision(HarnessEventTestsSupport.decision()))
  }

  static func setModified(_ url: URL, daysAgo: Double) throws {
    try FileManager.default.setAttributes(
      [.modificationDate: now.addingTimeInterval(-daysAgo * day)], ofItemAtPath: url.path)
  }

  /// Every regular file under `root`'s `.harness/events/`, relative to `root`.
  static func eventFiles(_ root: URL) throws -> Set<String> {
    let events = StateRoot.tree(root).url(RunLayout.eventsDirectory)
    var found: Set<String> = []
    for path in try FileManager.default.subpathsOfDirectory(atPath: events.path) {
      var isDirectory: ObjCBool = false
      guard
        FileManager.default.fileExists(
          atPath: events.appending(path: path).path, isDirectory: &isDirectory),
        !isDirectory.boolValue
      else { continue }
      found.insert("\(RunLayout.eventsDirectory)/\(path)")
    }
    return found
  }

  /// A store at `root` with a 40-day-old sealed segment, a 10-day-old one and an active file. Each
  /// segment's files carry an mtime opposite to its index's time.
  static func makeStore(_ root: URL) throws {
    let sealing = HarnessEventFiles(root: root, rotationBytes: { _ in 1 })
    try sealing.append(event("forty-days", daysAgo: 40))
    try sealing.append(event("ten-days", daysAgo: 10))
    try HarnessEventFiles(root: root).append(event("active", daysAgo: 50))
    let sealed = StateRoot.tree(root).url(EventSegmentLayout.sealedDirectory(.judge))
    try Data("{}".utf8).write(to: sealed.appending(path: "1.rollup.json"))
    for name in try FileManager.default.contentsOfDirectory(atPath: sealed.path) {
      try setModified(sealed.appending(path: name), daysAgo: name.hasPrefix("1.") ? 1 : 60)
    }
    try setModified(StateRoot.tree(root).url(RunLayout.eventsFile(.judge)), daysAgo: 60)
  }

  @Test(
    "gc leaves every event file without --events, and with --events --older-than 30 removes the 40-day segment, its index and rollup, here and in an imported store, keeping the 10-day one and the active file — catches gc deleting events unasked, or by file mtime instead of the index's last time"
  )
  func eventsOnlyWhenAskedByIndexTime() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "swiftgate-gc-events-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try Self.makeStore(root)
    let worker = root.appending(path: "worker", directoryHint: .isDirectory)
    try Self.makeStore(worker)
    let imported = StateRoot.tree(root).url("\(EventCopyUp.importedDirectory)/store-1")
    try FileManager.default.createDirectory(
      at: imported.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.moveItem(
      at: StateRoot.tree(worker).url(RunLayout.eventsDirectory), to: imported)
    let before = try Self.eventFiles(root)

    let plain = await GCRun.run(root: root, maxAgeDays: 7, now: Self.now) { [String]() }

    #expect(try Self.eventFiles(root) == before)
    #expect(plain.removedEvents.isEmpty)

    let summary = await GCRun.run(
      root: root, maxAgeDays: 7, eventsOlderThanDays: 30, now: Self.now
    ) { [String]() }

    let sealed = EventSegmentLayout.sealedDirectory(.judge)
    let importedSealed = "\(EventCopyUp.importedDirectory)/store-1/sealed/judge"
    let gone = Set(
      [sealed, importedSealed].flatMap { directory in
        ["1.jsonl.lzfse", "1.index.json", "1.rollup.json"].map { "\(directory)/\($0)" }
      })
    #expect(summary.errors.isEmpty, "\(summary.errors)")
    #expect(Set(summary.removedEvents) == Set(gone.map(RunLayout.treePath)))
    #expect(try Self.eventFiles(root) == before.subtracting(gone))
    #expect(before.contains(RunLayout.eventsFile(.judge)))
    #expect(before.contains("\(sealed)/2.jsonl.lzfse"))
  }
}

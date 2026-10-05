import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("span log")
struct SpanLogTests {
  static let origin = Date(timeIntervalSince1970: 1_790_000_000)
  static let spanID = "5a1e0c0d5a1e0c0d"

  static func temporaryRoot() -> URL {
    TestTemporaryDirectory.root.appending(
      path: "swiftgate-span-log-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  static func log(_ root: URL, at seconds: Double, id: String) -> SpanLog {
    SpanLog(
      root: root, now: { origin.addingTimeInterval(seconds) }, newEventID: { id },
      newSpanID: { spanID })
  }

  static func start(_ root: URL, id: String = "start-1") throws -> HarnessEvent {
    try log(root, at: 0, id: id).start(
      phase: .verify, buildRun: "run-1", task: "task-1", role: .review, parentSpan: nil)
  }

  static func spanLines(_ root: URL) throws -> [HarnessEvent] {
    guard let data = try HarnessEventFiles(root: root).read(.span, runID: nil) else { return [] }
    return try HarnessEventJSON.decode(data).events
  }

  static func appendRaw(_ text: String, to root: URL) throws {
    let file = StateRoot.tree(root).url(RunLayout.eventsFile(.span))
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
    try handle.close()
  }

  @Test(
    "an end finds a start that rotated into a sealed segment — catches reading only the active file"
  )
  func endFindsASealedStart() throws {
    let root = Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let start = HarnessEvent(
      eventID: "start-sealed", time: Self.origin, source: HarnessEventSource(route: nil),
      payload: .spanStart(
        SpanStartEvent(
          spanID: Self.spanID, parentSpan: nil, phase: .fix, buildRun: "run-1", task: "task-1",
          role: .buildWorker)))
    try HarnessEventFiles(root: root, rotationBytes: { _ in 1 }).append(start)
    let active = StateRoot.tree(root).url(RunLayout.eventsFile(.span))
    #expect(
      !FileManager.default.fileExists(atPath: active.path), "the start stayed in the active file")

    let end = try Self.log(root, at: 42, id: "end-1").end(spanID: Self.spanID, outcome: .ok)

    #expect(end.parentID == "start-sealed")
    #expect(
      end.payload == .spanEnd(SpanEndEvent(spanID: Self.spanID, outcome: .ok, milliseconds: 42_000))
    )
  }

  @Test(
    "a torn last line from a crashed write doesn't stop an end of an earlier start — catches 1 cut write locking every span open"
  )
  func tornLastLineDoesNotBlockAnEnd() throws {
    let root = Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try Self.start(root)
    try Self.appendRaw(#"{"eventID":"cut"#, to: root)

    let end = try Self.log(root, at: 3, id: "end-1").end(spanID: Self.spanID, outcome: .halted)

    #expect(end.parentID == "start-1")
  }

  @Test(
    "an undecodable line before the end fails it as unreadable and writes nothing — catches a damaged end hidden behind a second end"
  )
  func undecodableLineFailsTheEnd() throws {
    let root = Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try Self.start(root)
    try Self.appendRaw("{\"not\":\"an event\"}\n", to: root)

    #expect {
      _ = try Self.log(root, at: 3, id: "end-1").end(spanID: Self.spanID, outcome: .ok)
    } throws: { error in
      guard case .unreadable(let path, _) = error as? SpanLogError else { return false }
      return path.hasSuffix(RunLayout.eventsFile(.span))
    }
    let active = StateRoot.tree(root).url(RunLayout.eventsFile(.span))
    #expect(try String(contentsOf: active, encoding: .utf8).split(separator: "\n").count == 2)
  }

  @Test("concurrent ends of 1 span close it once — catches a race outside the lock")
  func concurrentEndsCloseOnce() async throws {
    let root = Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try Self.start(root)
    let enders = 8

    let results = await withTaskGroup(of: Result<HarnessEvent, SpanLogError>.self) { group in
      for ender in 0..<enders {
        group.addTask {
          await OffPool.run {
            Result { () throws(SpanLogError) -> HarnessEvent in
              try Self.log(root, at: 5, id: "end-\(ender)").end(spanID: Self.spanID, outcome: .ok)
            }
          }
        }
      }
      return await group.reduce(into: []) { $0.append($1) }
    }

    let refusals = results.compactMap { result -> SpanLogError? in
      guard case .failure(let error) = result else { return nil }
      return error
    }
    #expect(results.count - refusals.count == 1)
    #expect(refusals == Array(repeating: .alreadyEnded(spanID: Self.spanID), count: enders - 1))
    #expect(try Self.spanLines(root).count == 2)
  }
}

@Suite("ending a build run's open spans")
struct SpanLogEndOpenTests {
  static let buildRun = "20261005T055727Z-2fbf5ab4"

  @Test(
    "on the third price-tracker trial's spans, the cutoff ends its abandoned tasks' open spans as abandoned, the finish ends the last task span, and the run's own spans are never touched — catches a killed worker's or a forgotten review's span left open forever"
  )
  func endsOpenSpansByTask() throws {
    let root = SpanLogTests.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let captured = try HarnessEventJSON.decode(
      Fixture.data("BrownfieldTrial/price-tracker-3-spans.jsonl")
    ).events
    for event in captured { try HarnessEventFiles(root: root).append(event) }
    let at = try #require(ISO8601DateFormatter().date(from: "2026-10-05T06:28:20Z"))
    let log = SpanLog(root: root, now: { at })

    let abandoned: Set<String> = ["watchlist-screen", "detail-screen"]
    let cutoff = try log.endOpen(buildRun: Self.buildRun, outcome: .abandoned) {
      $0.task.map(abandoned.contains) ?? false
    }
    let finish = try log.endOpen(buildRun: Self.buildRun, outcome: .abandoned) { $0.task != nil }
    let again = try log.endOpen(buildRun: Self.buildRun, outcome: .abandoned) { _ in true }

    func ended(_ events: [HarnessEvent]) -> [String] {
      events.compactMap { if case .spanEnd(let end) = $0.payload { end.spanID } else { nil } }
    }
    #expect(ended(cutoff) == ["f4102dced11585b9", "dd827de42d1b55e5"])
    #expect(ended(finish) == ["b5bd65c39f79bed5"])
    #expect(ended(again).isEmpty)
    guard case .spanEnd(let worker)? = cutoff.first?.payload else {
      Issue.record("the cutoff wrote no span end")
      return
    }
    #expect(worker.outcome == .abandoned)
    #expect(abs(worker.milliseconds - 1_830_376) <= 1, "\(worker.milliseconds)")
    #expect(OpenSpans.of(try SpanLogTests.spanLines(root), buildRun: Self.buildRun).isEmpty)
  }
}

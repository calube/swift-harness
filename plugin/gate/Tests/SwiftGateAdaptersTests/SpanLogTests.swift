import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import Testing

@Suite("span log")
struct SpanLogTests {
  static let origin = Date(timeIntervalSince1970: 1_790_000_000)
  static let spanID = "5a1e0c0d5a1e0c0d"

  static func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appending(
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

    let closed = await withTaskGroup(of: Bool.self) { group in
      for ender in 0..<enders {
        group.addTask {
          (try? Self.log(root, at: 5, id: "end-\(ender)").end(spanID: Self.spanID, outcome: .ok))
            != nil
        }
      }
      return await group.reduce(into: 0) { $0 += $1 ? 1 : 0 }
    }

    #expect(closed == 1)
    #expect(try Self.spanLines(root).count == 2)
  }
}

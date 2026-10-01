import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import Synchronization
import Testing

@Suite("event store reader: active files, sealed segments and imported stores")
struct EventStoreReaderTests {
  typealias Store = EventSegmentStoreTests

  /// Reads from disk and remembers every path it read.
  final class CountingFiles: EventStoreFileReading {
    let inner: LiveEventStoreFiles
    private let reads = Mutex<[String]>([])

    init(root: URL) {
      inner = LiveEventStoreFiles(root: root)
    }

    var paths: [String] { reads.withLock { $0 } }

    func read(_ path: String) throws(EventStoreFileError) -> Data? {
      reads.withLock { $0.append(path) }
      return try inner.read(path)
    }

    func list(_ directory: String) throws(EventStoreFileError) -> [String] {
      try inner.list(directory)
    }

    func size(_ path: String) throws(EventStoreFileError) -> Int? {
      try inner.size(path)
    }
  }

  static func run(_ hour: Int) -> String {
    "20260930T\(String(format: "%02d", hour))0000Z-0000abcd"
  }

  @Test(
    "a torn last line in an active file is left out and listed as damage naming the file and line — catches a silent drop"
  )
  func tornActiveLineIsDamage() throws {
    let root = Store.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try HarnessEventFiles(root: root).append(contentsOf: [
      Store.decision("a", second: 0), Store.decision("b", second: 1),
    ])
    let active = root.appending(path: RunLayout.eventsFile(.judge))
    let handle = try FileHandle(forWritingTo: active)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"schemaVersion\":1,\"eventID\":\"c".utf8))
    try handle.close()

    let read = EventStoreReader(files: LiveEventStoreFiles(root: root)).read(EventQuery())
    #expect(read.events.map(\.event.eventID) == ["a", "b"])
    #expect(
      read.damage == [
        EventDamage(
          file: ".harness/events/judge.jsonl", line: 3, kind: .tornLastLine, detail: nil)
      ])
  }

  @Test(
    "the same event in the worktree's store and an imported copy is read once, and an imported-only event is read too — catches a reader that skips or doubles imports"
  )
  func importedCopyIsDeduplicated() throws {
    let root = Store.temporaryRoot()
    let worker = Store.temporaryRoot()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: worker)
    }
    try HarnessEventFiles(root: root).append(Store.decision("shared", second: 1))
    try HarnessEventFiles(root: worker).append(contentsOf: [
      Store.decision("shared", second: 1), Store.decision("worker-only", second: 0),
    ])
    let imported = root.appending(path: "\(RunLayout.eventsDirectory)/imported/store-1")
    try FileManager.default.createDirectory(
      at: imported.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: worker.appending(path: RunLayout.eventsDirectory), to: imported)

    let read = EventStoreReader(files: LiveEventStoreFiles(root: root)).read(EventQuery())
    #expect(read.events.map(\.event.eventID) == ["worker-only", "shared"])
    #expect(read.damage.isEmpty)
    #expect(read.facts.stores == 2)
  }

  @Test(
    "a run query opens only the sealed segments whose index names the run, and still reads the active file — catches a reader that decompresses everything"
  )
  func runQueryOpensOnlyItsSegments() throws {
    let root = Store.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // Every write past 1 byte rotates, so each batch below becomes 1 sealed segment.
    let writer = HarnessEventFiles(root: root, rotationBytes: { _ in 1 })
    for hour in 10...13 {
      try writer.append(contentsOf: [
        Store.decision("e\(hour)a", runID: Self.run(hour), second: Double(hour)),
        Store.decision("e\(hour)b", runID: Self.run(hour), second: Double(hour) + 0.5),
      ])
    }
    let sealed = EventSegmentLayout.sealedDirectory(.judge)
    #expect(
      Store.names(in: root.appending(path: sealed)).filter { $0.hasSuffix(".lzfse") }.count == 4)

    let files = CountingFiles(root: root)
    let read = EventStoreReader(files: files).read(EventQuery(runID: Self.run(12)))
    #expect(read.events.map(\.event.eventID) == ["e12a", "e12b"])
    let segments = files.paths.filter { $0.hasPrefix(sealed) && !$0.hasSuffix(".index.json") }
    #expect(segments == ["\(sealed)/3.jsonl.lzfse"])
    #expect(read.facts.streams.first?.sealedSegments == 4)

    let everything = CountingFiles(root: root)
    let all = EventStoreReader(files: everything).read(EventQuery())
    #expect(all.events.count == 8)
    #expect(
      everything.paths.filter { $0.hasPrefix(sealed) && $0.hasSuffix(".lzfse") }.count == 4)
  }

  @Test(
    "an undecodable line in a sealed segment and an unreadable index are damage, and the segment's other events still read — catches a bad segment dropping its good lines"
  )
  func damagedSegmentKeepsItsGoodLines() throws {
    let root = Store.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sealed = root.appending(path: EventSegmentLayout.sealedDirectory(.judge))
    try FileManager.default.createDirectory(at: sealed, withIntermediateDirectories: true)
    var lines = try Store.lines([Store.decision("a", runID: Self.run(10))])
    lines.append(Data("not json\n".utf8))
    lines.append(try Store.lines([Store.decision("b", runID: Self.run(10), second: 1)]))
    try lines.write(to: sealed.appending(path: "1.jsonl"))
    try Data("{".utf8).write(to: sealed.appending(path: "1.index.json"))

    let read = EventStoreReader(files: LiveEventStoreFiles(root: root)).read(
      EventQuery(runID: Self.run(10)))
    #expect(read.events.map(\.event.eventID) == ["a", "b"])
    let file = "\(EventSegmentLayout.sealedDirectory(.judge))/1.jsonl"
    #expect(read.damage.map(\.kind) == [.unreadableIndex, .undecodableLine])
    #expect(read.damage.last?.file == file)
    #expect(read.damage.last?.line == 2)
  }

  @Test(
    "the facts hold each stream's active and sealed bytes and every store's drop counts — catches facts read from 1 store only"
  )
  func factsSumEveryStore() throws {
    let root = Store.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try HarnessEventFiles(root: root).append(Store.decision("a"))
    var dropped = EventDropCounts()
    dropped.count(.judgeCall, .newline)
    let encoded = try JSONEncoder().encode(dropped)
    try encoded.write(to: root.appending(path: EventSegmentLayout.droppedFile))
    let imported = root.appending(path: "\(RunLayout.eventsDirectory)/imported/store-1")
    try FileManager.default.createDirectory(at: imported, withIntermediateDirectories: true)
    try encoded.write(to: imported.appending(path: "dropped.json"))

    let read = EventStoreReader(files: LiveEventStoreFiles(root: root)).read(EventQuery())
    let size =
      try FileManager.default.attributesOfItem(
        atPath: root.appending(path: RunLayout.eventsFile(.judge)).path)[.size] as? Int
    #expect(read.facts.streams.first?.activeBytes == size)
    #expect(read.facts.dropped.dropped[.judgeCall]?[.newline] == 2)
    #expect(read.events.first?.bytes == size)
  }
}

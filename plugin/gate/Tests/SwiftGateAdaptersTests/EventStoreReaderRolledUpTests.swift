import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import Testing

@Suite("the event reader counts rolled-up sealed test segments from their indexes when asked")
struct EventStoreReaderRolledUpTests {
  typealias Captured = TestRollupStoreTests
  typealias Counting = EventStoreReaderTests.CountingFiles

  static func index(_ root: URL, _ sequence: Int) throws -> EventSegmentIndex {
    try EventSegmentIndex.decode(
      Data(
        contentsOf: root.appending(
          path: "\(Captured.sealed)/\(EventSegmentLayout.indexName(sequence))")))
  }

  @Test(
    "asked for indexes, the reader opens no rolled-up test segment and its facts hold the indexes' lines and bytes; asked for lines, it decodes them all — catches the mode ignored either way"
  )
  func indexesStandInForRolledUpSegments() throws {
    let root = try Captured.capturedStore(runs: 2, rotationBytes: 1 << 20)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = Counting(root: root)

    let read = EventStoreReader(files: files).read(
      EventQuery(), sealedTests: .indexesWhereRolledUp)

    #expect(files.paths.filter(Captured.isSegment).isEmpty)
    #expect(read.events.allSatisfy { $0.event.kind != .testResult })
    let indexes = [try Self.index(root, 1), try Self.index(root, 2)]
    #expect(
      read.facts.rolledUpTests
        == EventStoreFacts.RolledUpTests(
          segments: 2, lines: indexes.reduce(0) { $0 + $1.lines },
          bytes: indexes.reduce(0) { $0 + $1.bytes }))

    let whole = EventStoreReader(files: LiveEventStoreFiles(root: root)).read(EventQuery())
    #expect(whole.facts.rolledUpTests == nil)
    #expect(whole.events.filter { $0.event.kind == .testResult }.count == 2 * 2_677)
  }

  @Test(
    "a rolled-up segment whose index is gone is decoded, since nothing else can count it — catches a segment counted from an index it doesn't have"
  )
  func segmentWithoutIndexIsDecoded() throws {
    let root = try Captured.capturedStore(runs: 2, rotationBytes: 1 << 20)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.removeItem(
      at: root.appending(path: "\(Captured.sealed)/\(EventSegmentLayout.indexName(1))"))
    let files = Counting(root: root)

    let read = EventStoreReader(files: files).read(
      EventQuery(), sealedTests: .indexesWhereRolledUp)

    #expect(
      files.paths.filter(Captured.isSegment) == [
        "\(Captured.sealed)/\(EventSegmentLayout.compressedName(1))"
      ])
    #expect(read.events.filter { $0.event.kind == .testResult }.count == 2_677)
    #expect(read.facts.rolledUpTests?.segments == 1)
  }
}

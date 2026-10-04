import CryptoKit
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("event store: guard, rotation, sealing, identity and the writer factory")
struct EventSegmentStoreTests {
  static func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appending(
      path: "swiftgate-segments-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  static func decision(
    _ id: String, runID: String? = nil, file: String = "Tests/PassTests.swift",
    reason: String? = nil, rationale: String? = nil, second: Double = 0
  ) -> HarnessEvent {
    HarnessEvent(
      eventID: id, time: Date(timeIntervalSince1970: 1_790_000_000 + second), runID: runID,
      source: HarnessEventSource(route: .judgeTests),
      payload: .judgeDecision(
        JudgeDecisionEvent(
          subject: JudgeEventSubject(
            id: "PassTests/doubles()", file: file, line: 1, sourceSHA256: "00"),
          questionSet: "test-quality@1", questionSetVersion: 1, question: "fails-if-broken",
          blocking: true, atReadyTier: false, backend: .claude, model: "sonnet",
          servedModel: nil, distribution: ["yes": 1, "no": 0], p: 0,
          thresholds: JudgeEventThresholds(JudgeThresholds(advisory: 0.6, block: 0.9)),
          band: nil, inBand: nil, escalated: false, escalation: nil, decision: .block,
          severity: .major, decidedBy: "claude/sonnet", reasonSource: .claude, reason: reason,
          reasonError: nil, rationale: rationale, cacheHit: false, calls: [], error: nil)))
  }

  static func lines(_ events: [HarnessEvent]) throws -> Data {
    try events.reduce(into: Data()) { $0.append(try HarnessEventJSON.encodeLine($1)) }
  }

  static func names(in directory: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
  }

  @Test(
    "8 writers, each opening its own descriptor, append 500 events each while the log rotates and seals under them, and the segments plus the active file hold 4,000 whole lines, every id once — catches a write outside the lock or into a file already rotated away"
  )
  func concurrentWritersAcrossRotation() async throws {
    let root = Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = HarnessEventFiles(root: root, rotationBytes: { _ in 64 << 10 })
    let store = EventSegmentStore(root: root, rotationBytes: { _ in 64 << 10 })

    try await withThrowingTaskGroup(of: Void.self) { group in
      for writer in 0..<8 {
        group.addTask {
          for index in 0..<500 { try files.append(Self.decision("w\(writer)-\(index)")) }
        }
      }
      try await group.waitForAll()
    }

    let data = try #require(try files.read(.judge, runID: nil))
    let read = try HarnessEventJSON.decode(data)
    #expect(!read.tornLastLine)
    #expect(read.events.count == 4_000)
    #expect(Set(read.events.map(\.eventID)).count == 4_000)
    let segments = try store.segments(.judge)
    #expect(segments.count > 1)
    var indexed = 0
    for sequence in segments {
      indexed += try #require(try store.index(.judge, sequence: sequence)).lines
    }
    let active = try Data(contentsOf: URL(filePath: store.activePath(.judge)))
    #expect(indexed + (try HarnessEventJSON.decode(active)).events.count == 4_000)
    #expect(
      Self.names(in: store.sealedDirectory(.judge)).allSatisfy {
        !$0.hasSuffix(".jsonl") && !$0.hasSuffix(".tmp")
      })
  }

  @Test(
    "with the guard on, an absolute path 2 levels into the payload, a ~ path, a newline and a 512-byte string are each dropped and counted by reason, the batch's clean event is still written, and the write throws naming the kind — catches a guard that checks only top-level fields or drops silently"
  )
  func guardDropsAndCounts() throws {
    let root = Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = HarnessEventFiles(root: root, guardPolicy: { _ in .enforced })
    let store = EventSegmentStore(root: root)
    let batch = [
      Self.decision("abs", file: "/Users/someone/App/Tests/A.swift"),
      Self.decision("home", file: "~/App/Tests/A.swift"),
      Self.decision("newline", reason: "first\nsecond"),
      Self.decision("long", reason: String(repeating: "x", count: 512)),
      Self.decision("clean", reason: "the doubled value is never compared"),
    ]

    #expect(throws: HarnessEventWriteError.self) { try files.append(contentsOf: batch) }
    do {
      try files.append(Self.decision("abs-again", file: "/tmp/A.swift"))
    } catch {
      #expect(error.reason.contains("judge.decision"))
      #expect(error.reason.contains("absolute-path"))
    }

    let read = try HarnessEventJSON.decode(try #require(try files.read(.judge, runID: nil)))
    #expect(read.events.map(\.eventID) == ["clean"])
    #expect(
      try store.dropped().dropped
        == [.judgeDecision: [.absolutePath: 2, .homePath: 1, .newline: 1, .tooLong: 1]])
    #expect(
      FileManager.default.fileExists(
        atPath: StateRoot.tree(root).url(EventSegmentLayout.droppedFile).path))
  }

  @Test(
    "under the default guard a judge decision keeps a 3,000-byte Claude reason and rationale with newlines and a leading path whole, and nothing is counted as dropped — catches the payload guard cutting or dropping the audit trail"
  )
  func judgeReasonSurvives() throws {
    let root = Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = HarnessEventFiles(root: root)
    let store = EventSegmentStore(root: root)
    let reason =
      "/Sources/App/Doubler.swift returns its input unchanged under the mutant.\n"
      + String(repeating: "Nothing compares doubled(2) to 4, so the test stays green. ", count: 50)
    let rationale = "~ the assertion only checks it doesn't throw\n" + reason
    let event = Self.decision("long-reason", reason: reason, rationale: rationale)

    try files.append(event)

    let read = try HarnessEventJSON.decode(try #require(try files.read(.judge, runID: nil)))
    #expect(read.events == [event])
    guard case .judgeDecision(let decision) = try #require(read.events.first).payload else {
      Issue.record("not a decision")
      return
    }
    #expect(decision.reason == reason)
    #expect(decision.rationale == rationale)
    #expect((decision.reason?.utf8.count ?? 0) > 3_000)
    #expect(try store.dropped() == EventDropCounts())
    let guarded = HarnessEventFiles(root: Self.temporaryRoot(), guardPolicy: { _ in .enforced })
    defer { try? FileManager.default.removeItem(at: guarded.root) }
    #expect(throws: HarnessEventWriteError.self) { try guarded.append(event) }
  }

  @Test(
    "the write that crosses the threshold rotates and seals the file whole, a batch written just under the threshold stays in 1 segment, and the next write starts a new active file — catches a batch split across segments or a rotation that loses the tail"
  )
  func rotationKeepsBatchesWhole() throws {
    let root = Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let threshold = 16 << 10
    let files = HarnessEventFiles(root: root, rotationBytes: { _ in threshold })
    let store = EventSegmentStore(root: root, rotationBytes: { _ in threshold })
    let one = try Self.lines([Self.decision("probe")]).count
    let before = (threshold - 1_024) / one
    for index in 0..<before { try files.append(Self.decision("before-\(index)")) }
    let active = store.activePath(.judge)
    let sizeBefore = try #require(
      try FileManager.default.attributesOfItem(atPath: active)[.size] as? Int)
    #expect(sizeBefore < threshold)
    let batch = (0..<(3_072 / one + 1)).map { Self.decision("batch-\($0)", runID: "run-b") }

    try files.append(contentsOf: batch)

    #expect(!FileManager.default.fileExists(atPath: active))
    #expect(
      Self.names(in: store.sealedDirectory(.judge)) == ["1.index.json", "1.jsonl.lzfse"])
    let sealed = try HarnessEventJSON.decode(try store.segment(.judge, sequence: 1))
    #expect(sealed.events.map(\.eventID).suffix(batch.count) == batch.map(\.eventID)[...])
    #expect(sealed.events.count == before + batch.count)

    try files.append(Self.decision("after"))

    let next = try HarnessEventJSON.decode(try Data(contentsOf: URL(filePath: active)))
    #expect(next.events.map(\.eventID) == ["after"])
    let all = try HarnessEventJSON.decode(try #require(try files.read(.judge, runID: nil)))
    #expect(all.events.count == before + batch.count + 1)
  }

  @Test(
    "a rotated segment a killed sealer left plain reads back in order before the active file, and the next sealing pass seals it — catches a killed sealer losing lines"
  )
  func plainSegmentReadsBack() throws {
    let root = Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = HarnessEventFiles(root: root)
    let store = EventSegmentStore(root: root)
    let directory = store.sealedDirectory(.judge)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Self.lines([Self.decision("old-1"), Self.decision("old-2")])
      .write(to: directory.appending(path: EventSegmentLayout.plainName(1)))
    try files.append(Self.decision("new"))

    let read = try HarnessEventJSON.decode(try #require(try files.read(.judge, runID: nil)))
    #expect(read.events.map(\.eventID) == ["old-1", "old-2", "new"])

    try store.sealPending(.judge)

    #expect(Self.names(in: directory) == ["1.index.json", "1.jsonl.lzfse"])
    let sealed = try HarnessEventJSON.decode(try #require(try files.read(.judge, runID: nil)))
    #expect(sealed.events.map(\.eventID) == ["old-1", "old-2", "new"])
  }

  @Test(
    "2 sealers racing on 1 plain segment leave exactly 1 compressed file and 1 index, no plain or temporary file, and the same lines, in each of 20 trials — catches 2 sealers both creating, or 1 removing what the other still reads"
  )
  func sealersRace() async throws {
    for trial in 0..<20 {
      let root = Self.temporaryRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let store = EventSegmentStore(root: root)
      let directory = store.sealedDirectory(.judge)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let lines = try Self.lines(
        (0..<200).map { Self.decision("t\(trial)-\($0)", runID: "run-\($0 % 3)") })
      try lines.write(to: directory.appending(path: EventSegmentLayout.plainName(1)))

      try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<2 { group.addTask { try store.sealPending(.judge) } }
        try await group.waitForAll()
      }

      #expect(Self.names(in: directory) == ["1.index.json", "1.jsonl.lzfse"], "trial \(trial)")
      #expect(try store.segment(.judge, sequence: 1) == lines, "trial \(trial)")
      #expect(try store.index(.judge, sequence: 1)?.lines == 200, "trial \(trial)")
    }
  }

  @Test(
    "a sealed segment's index names exactly the run ids its events carry, and its counts, times and SHA-256 match the uncompressed lines — catches an index that would send --run to the wrong segment"
  )
  func indexNamesItsRuns() throws {
    let root = Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = HarnessEventFiles(root: root, rotationBytes: { _ in 1 })
    let store = EventSegmentStore(root: root, rotationBytes: { _ in 1 })
    let batch = [
      Self.decision("a", runID: "20260930T120000Z-0000aaaa", second: 1),
      Self.decision("b", runID: nil, second: 2),
      Self.decision("c", runID: "20260930T110000Z-0000bbbb", second: 3),
      Self.decision("d", runID: "20260930T120000Z-0000aaaa", second: 4),
    ]

    try files.append(contentsOf: batch)
    try files.append(Self.decision("e", runID: "20260930T130000Z-0000cccc", second: 5))

    let lines = try Self.lines(batch)
    let index = try #require(try store.index(.judge, sequence: 1))
    #expect(index.runIDs == ["20260930T110000Z-0000bbbb", "20260930T120000Z-0000aaaa"])
    #expect(index.lines == 4)
    #expect(index.bytes == lines.count)
    #expect(index.sha256 == SHA256.hash(data: lines).map { String(format: "%02x", $0) }.joined())
    #expect(index.firstTime == Date(timeIntervalSince1970: 1_790_000_001))
    #expect(index.lastTime == Date(timeIntervalSince1970: 1_790_000_004))
    let compressed = store.sealedDirectory(.judge)
      .appending(path: EventSegmentLayout.compressedName(1))
    #expect(
      index.compressedBytes
        == (try FileManager.default.attributesOfItem(atPath: compressed.path)[.size] as? Int))
    #expect(try store.index(.judge, sequence: 2)?.runIDs == ["20260930T130000Z-0000cccc"])
  }

  @Test(
    "the store identity is created once on first write, with a random id and 32-byte salt, and concurrent callers all get that one — catches 2 writers each creating an identity and an imported store losing its name"
  )
  func identityIsCreatedOnce() async throws {
    let root = Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = EventSegmentStore(root: root)

    let identities = try await withThrowingTaskGroup(of: EventStoreIdentity.self) { group in
      for _ in 0..<8 { group.addTask { try store.identity() } }
      return try await group.reduce(into: [EventStoreIdentity]()) { $0.append($1) }
    }

    #expect(Set(identities.map(\.storeID)).count == 1)
    let identity = try #require(identities.first)
    #expect(identity.salt.count == 64)
    let stored = try JSONDecoder().decode(
      EventStoreIdentity.self,
      from: try Data(contentsOf: StateRoot.tree(root).url(EventSegmentLayout.storeFile)))
    #expect(stored == identity)
    let other = try EventSegmentStore(root: Self.temporaryRoot()).identity()
    #expect(other.storeID != identity.storeID)
    #expect(other.salt != identity.salt)

    let written = Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: written) }
    try HarnessEventFiles(root: written).append(Self.decision("first"))
    #expect(
      FileManager.default.fileExists(
        atPath: StateRoot.tree(written).url(EventSegmentLayout.storeFile).path))
  }

  @Test(
    "the disabled factory's writer keeps nothing and creates no directory, while the enabled one writes the event — catches telemetry written after the user opted out"
  )
  func disabledFactoryWritesNothing() throws {
    let root = Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    try EventWriterFactory.make(root: root, enabled: false)
      .append(contentsOf: [Self.decision("off-1"), Self.decision("off-2")])
    try EventWriterFactory.make(root: root, enabled: false).append(Self.decision("off-3"))

    #expect(!FileManager.default.fileExists(atPath: root.path))
    try EventWriterFactory.make(root: root, enabled: true).append(Self.decision("on"))
    let read = try HarnessEventJSON.decode(
      try #require(try HarnessEventFiles(root: root).read(.judge, runID: nil)))
    #expect(read.events.map(\.eventID) == ["on"])
  }

  @Test(
    "a judge log the writer wrote before segments existed reads whole, and still reads whole after a later write rotates it into a sealed segment — catches today's audit log unreadable after the store changes"
  )
  func legacyJudgeLogReads() throws {
    let root = Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = try Fixture.data("Events/judge.jsonl")
    let active = StateRoot.tree(root).url(RunLayout.eventsFile(.judge))
    try FileManager.default.createDirectory(
      at: active.deletingLastPathComponent(), withIntermediateDirectories: true)
    try legacy.write(to: active)
    let expected = try HarnessEventJSON.decode(legacy).events
    #expect(expected.count == 24)

    let before = try HarnessEventJSON.decode(
      try #require(try HarnessEventFiles(root: root).read(.judge, runID: nil)))
    #expect(before.events == expected)

    let files = HarnessEventFiles(root: root, rotationBytes: { _ in legacy.count })
    try files.append(Self.decision("after-rotation"))

    #expect(!FileManager.default.fileExists(atPath: active.path))
    let after = try HarnessEventJSON.decode(try #require(try files.read(.judge, runID: nil)))
    #expect(after.events.dropLast() == expected[...])
    #expect(after.events.last?.eventID == "after-rotation")
    let summary = JudgeEventSummary.make(after, filter: JudgeEventFilter())
    #expect(summary.events == expected.count + 1)
    #expect(summary.blocks.contains { $0.reason?.hasPrefix("The test calls doubled(2)") == true })
  }

  @Test(
    "a rotated segment that won't index stays plain and readable, and the write that rotated it throws naming the segment while its event is kept — catches a damaged segment compressed away or a seal failure passed off as a lost write"
  )
  func unsealableSegmentStaysPlain() throws {
    let root = Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = HarnessEventFiles(root: root, rotationBytes: { _ in 1 })
    let store = EventSegmentStore(root: root, rotationBytes: { _ in 1 })
    let active = URL(filePath: store.activePath(.judge))
    try FileManager.default.createDirectory(
      at: active.deletingLastPathComponent(), withIntermediateDirectories: true)
    try (try Self.lines([Self.decision("whole")]) + Data("{\"schemaVersion\":1,\"ev".utf8))
      .write(to: active)

    do {
      try files.append(Self.decision("kept"))
      Issue.record("the seal failure went unreported")
    } catch {
      #expect(error.reason.hasPrefix("written, but sealing failed"))
      #expect(error.path.hasSuffix("sealed/judge/1.index.json"))
    }

    #expect(Self.names(in: store.sealedDirectory(.judge)).contains("1.jsonl"))
    #expect(!Self.names(in: store.sealedDirectory(.judge)).contains("1.index.json"))
    let segment = try store.segment(.judge, sequence: 1)
    #expect(String(decoding: segment, as: UTF8.self).contains("\"eventID\":\"kept\""))
  }

  @Test(
    "a damaged store.json, dropped.json or index is reported naming its file and left as it was, never replaced — catches a store silently renamed or its drop counts reset"
  )
  func damagedStoreFilesAreReported() throws {
    let root = Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = EventSegmentStore(root: root)
    let events = StateRoot.tree(root).url(RunLayout.eventsDirectory)
    try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
    let identity = StateRoot.tree(root).url(EventSegmentLayout.storeFile)
    let dropped = StateRoot.tree(root).url(EventSegmentLayout.droppedFile)
    try Data("{\"storeID\":".utf8).write(to: identity)
    try Data("[]".utf8).write(to: dropped)
    let sealed = store.sealedDirectory(.judge)
    try FileManager.default.createDirectory(at: sealed, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: sealed.appending(path: EventSegmentLayout.indexName(1)))
    try Data("not lzfse".utf8).write(
      to: sealed.appending(path: EventSegmentLayout.compressedName(1)))

    do {
      _ = try store.identity()
      Issue.record("a damaged identity was accepted")
    } catch {
      #expect(error.path == identity.path)
    }
    do {
      try store.countDropped(.judgeCall, .tooLong)
      Issue.record("damaged drop counts were overwritten")
    } catch {
      #expect(error.path == dropped.path)
    }
    #expect(throws: HarnessEventReadError.self) { try store.index(.judge, sequence: 1) }
    #expect(throws: HarnessEventReadError.self) { try store.segment(.judge, sequence: 1) }
    #expect(throws: HarnessEventReadError.self) { try store.read(.judge) }
    #expect(try Data(contentsOf: identity) == Data("{\"storeID\":".utf8))
    #expect(try Data(contentsOf: dropped) == Data("[]".utf8))
  }

  @Test(
    "a writer with no batch write of its own keeps every event of a batch, in order — catches a batch silently dropped by an in-memory or wrapping writer"
  )
  func defaultBatchKeepsEvery() throws {
    let log = MemoryEventLog()

    try log.append(contentsOf: [Self.decision("1"), Self.decision("2"), Self.decision("3")])

    #expect(log.events.map(\.eventID) == ["1", "2", "3"])
  }
}

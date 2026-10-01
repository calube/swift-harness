import Foundation
import SwiftGateDomain
import Testing

@Suite("event payload guard, drop counts and segment names")
struct EventPayloadGuardTests {
  static func json(_ text: String) throws -> Any {
    try JSONSerialization.jsonObject(with: Data(text.utf8))
  }

  static func decision(file: String, reason: String?) -> HarnessEvent {
    HarnessEvent(
      eventID: "d-1", time: Date(timeIntervalSince1970: 1_790_000_000),
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
          reasonError: nil, rationale: nil, cacheHit: false, calls: [], error: nil)))
  }

  @Test(
    "an absolute path, a ~ path, a newline and a 512-byte string are each rejected with their own reason, at the top level and 2 levels down, while 511 bytes and a relative path pass — catches a guard that checks only top-level fields or is off by 1"
  )
  func rejectsEachShapeAtAnyDepth() throws {
    let long = String(repeating: "a", count: EventPayloadGuard.maxStringBytes)
    let cases: [(String, EventPayloadGuard.Reason)] = [
      ("/Users/someone/App/Sources/A.swift", .absolutePath),
      ("~/App/Sources/A.swift", .homePath),
      ("first\nsecond", .newline),
      (long, .tooLong),
    ]
    for (value, reason) in cases {
      let encoded = String(
        decoding: try JSONSerialization.data(withJSONObject: [value], options: .fragmentsAllowed),
        as: UTF8.self
      ).dropFirst().dropLast()
      #expect(
        EventPayloadGuard.rejection(inJSON: try Self.json("{\"id\":\(encoded)}")) == reason,
        "top level: \(reason)")
      #expect(
        EventPayloadGuard.rejection(
          inJSON: try Self.json("{\"id\":\"t\",\"cases\":[{\"ok\":1,\"file\":\(encoded)}]}"))
          == reason, "nested: \(reason)")
    }
    let multibyte = String(repeating: "é", count: EventPayloadGuard.maxStringBytes / 2)
    #expect(
      EventPayloadGuard.rejection(inJSON: try Self.json("{\"a\":{\"b\":\"\(multibyte)\"}}"))
        == .tooLong)
    let fits = String(repeating: "a", count: EventPayloadGuard.maxStringBytes - 1)
    #expect(
      EventPayloadGuard.rejection(
        inJSON: try Self.json(
          "{\"a\":{\"b\":[\"\(fits)\",\"Sources/App/A.swift\",\"a~b\"]},\"n\":3,\"t\":true}"))
        == nil)
  }

  @Test(
    "an event whose path sits 2 levels into its payload is rejected, the same event with a repo-relative path passes, and the judge stream is exempt — catches a guard that reads only the envelope, or one that drops audit decisions"
  )
  func eventPayloadIsWalked() throws {
    #expect(
      try EventPayloadGuard.rejection(
        of: Self.decision(file: "/private/var/T.swift", reason: nil)) == .absolutePath)
    #expect(try EventPayloadGuard.rejection(of: Self.decision(file: "T.swift", reason: nil)) == nil)
    #expect(
      try EventPayloadGuard.rejection(
        of: Self.decision(file: "T.swift", reason: "line 1\nline 2")) == .newline)
    #expect(EventPayloadGuard.policy(for: .judge) == .exempt)
  }

  @Test(
    "drop counts add up by kind and reason and encode as kind → reason → count, and a count file naming an unknown kind fails to decode — catches counts collapsed across reasons or a newer file misread"
  )
  func dropCountsByKindAndReason() throws {
    var counts = EventDropCounts()
    counts.count(.judgeCall, .tooLong)
    counts.count(.judgeCall, .tooLong)
    counts.count(.judgeCall, .absolutePath)
    counts.count(.judgeDecision, .newline)

    #expect(counts.dropped[.judgeCall] == [.tooLong: 2, .absolutePath: 1])
    #expect(counts.dropped[.judgeDecision] == [.newline: 1])
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let text = String(decoding: try encoder.encode(counts), as: UTF8.self)
    #expect(
      text
        == "{\"dropped\":{\"judge.call\":{\"absolute-path\":1,\"too-long\":2},\"judge.decision\":{\"newline\":1}},\"schemaVersion\":1}"
    )
    #expect(try JSONDecoder().decode(EventDropCounts.self, from: Data(text.utf8)) == counts)
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(
        EventDropCounts.self,
        from: Data("{\"dropped\":{\"mystery\":{\"newline\":1}},\"schemaVersion\":1}".utf8))
    }
  }

  @Test(
    "sealed directory names parse to their segment and role, and temporary or foreign names don't — catches a sealer's temporary file read as a segment"
  )
  func segmentFileNames() {
    #expect(EventSegmentLayout.file(named: "12.jsonl") == .plain(12))
    #expect(EventSegmentLayout.file(named: "3.jsonl.lzfse") == .compressed(3))
    #expect(EventSegmentLayout.file(named: "3.index.json") == .index(3))
    for name in [
      ".3.jsonl.lzfse.ab12.tmp", "a.jsonl", "3.jsonl.tmp", "-1.jsonl", "3.rollup.json", "jsonl",
    ] {
      #expect(EventSegmentLayout.file(named: name) == nil, "\(name)")
    }
    #expect(EventSegmentLayout.sealedDirectory(.judge) == ".harness/events/sealed/judge")
  }

  @Test(
    "a store identity takes exactly 32 bytes of salt as hex and decodes only a well-formed salt — catches a short or malformed salt weakening the hashes it keys"
  )
  func identityShape() throws {
    let id = try #require(UUID(uuidString: "6F1C2B4A-0000-4000-8000-00000000ABCD"))
    let identity = try #require(EventStoreIdentity(storeID: id, salt: Array(0..<32)))
    #expect(identity.storeID == "6f1c2b4a-0000-4000-8000-00000000abcd")
    #expect(identity.salt == (0..<32).map { String(format: "%02x", $0) }.joined())
    #expect(EventStoreIdentity(storeID: id, salt: Array(0..<31)) == nil)
    let decoded = try JSONDecoder().decode(
      EventStoreIdentity.self, from: try JSONEncoder().encode(identity))
    #expect(decoded == identity)
    let salt = String(repeating: "ab", count: 32)
    for (storeID, saltText, version) in [
      ("6f1c2b4a-0000-4000-8000-00000000abcd", "00", 1),
      ("6F1C2B4A-0000-4000-8000-00000000ABCD", salt, 1),
      ("not-a-uuid", salt, 1),
      ("6f1c2b4a-0000-4000-8000-00000000abcd", salt.uppercased(), 1),
      ("6f1c2b4a-0000-4000-8000-00000000abcd", salt, 2),
    ] {
      #expect(throws: DecodingError.self, "\(storeID) \(saltText) \(version)") {
        try JSONDecoder().decode(
          EventStoreIdentity.self,
          from: Data(
            "{\"salt\":\"\(saltText)\",\"schemaVersion\":\(version),\"storeID\":\"\(storeID)\"}"
              .utf8))
      }
    }
  }

  @Test(
    "an index is refused for an empty segment, one ending in a torn line, or a line that doesn't read, and an index file from a newer schema or with a bad time fails to decode — catches a damaged segment sealed as if whole"
  )
  func indexRefusesDamage() throws {
    let line = try HarnessEventJSON.encodeLine(Self.decision(file: "T.swift", reason: nil))
    #expect(throws: HarnessEventDecodeError.self) {
      try EventSegmentIndex.make(segment: Data(), compressedBytes: 0)
    }
    do {
      _ = try EventSegmentIndex.make(segment: line + line.prefix(20), compressedBytes: 0)
      Issue.record("a torn segment was indexed")
    } catch {
      #expect(error.line == 2)
      #expect(error.reason == .invalid("torn last line"))
    }
    #expect(throws: HarnessEventDecodeError.self) {
      try EventSegmentIndex.make(segment: Data("{}\n".utf8) + line, compressedBytes: 0)
    }
    let index = try EventSegmentIndex.make(segment: line, compressedBytes: 9)
    #expect(index.lines == 1)
    #expect(index.compressedBytes == 9)
    let text = String(decoding: try index.encoded(), as: UTF8.self)
    #expect(try EventSegmentIndex.decode(Data(text.utf8)) == index)
    #expect(throws: DecodingError.self) {
      try EventSegmentIndex.decode(
        Data(text.replacing("\"schemaVersion\":1", with: "\"schemaVersion\":2").utf8))
    }
    #expect(throws: DecodingError.self) {
      try EventSegmentIndex.decode(
        Data(text.replacing(/"firstTime":"[^"]*"/, with: "\"firstTime\":\"yesterday\"").utf8))
    }
  }
}

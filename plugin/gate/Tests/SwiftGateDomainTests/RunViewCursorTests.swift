import Foundation
import SwiftGateDomain
import Testing

@Suite("Run view cursor")
struct RunViewCursorTests {
  static func snapshot(_ files: [String: Int]) -> RunViewSnapshot {
    RunViewSnapshot(files: files.mapValues { RunViewSnapshot.Stamp(bytes: $0) })
  }

  @Test(
    "a snapshot's cursor names its files' lengths, not the order they were listed in — catches a cursor that misses an appended byte"
  )
  func cursorFollowsLengths() {
    let listed = Self.snapshot([".harness/events/build.jsonl": 120, "ledger log": 40])
    var reordered = RunViewSnapshot()
    reordered.files["ledger log"] = RunViewSnapshot.Stamp(bytes: 40)
    reordered.files[".harness/events/build.jsonl"] = RunViewSnapshot.Stamp(bytes: 120)
    let appended = Self.snapshot([".harness/events/build.jsonl": 121, "ledger log": 40])
    let rewritten = RunViewSnapshot(files: [
      ".harness/events/build.jsonl": RunViewSnapshot.Stamp(bytes: 120),
      "ledger log": RunViewSnapshot.Stamp(bytes: 40, modifiedNanoseconds: 7),
    ])

    #expect(!listed.cursor.isEmpty)
    #expect(listed.cursor == reordered.cursor)
    #expect(listed.cursor != appended.cursor)
    #expect(listed.cursor != rewritten.cursor)
    #expect(EventPayloadGuard.rejection(inJSON: listed.cursor) == nil)
  }}

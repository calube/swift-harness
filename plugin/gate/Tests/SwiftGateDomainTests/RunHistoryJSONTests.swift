import Foundation
import SwiftGateDomain
import Testing

@Suite("RunHistoryJSON")
struct RunHistoryJSONTests {
  static func line(base: String?) -> String {
    #"{"# + (base.map { #""base":""# + $0 + #"","# } ?? "")
      + #""command":"check push","durationMilliseconds":9360,"findingCount":0,"#
      + #""finishedAt":"2026-09-28T13:19:21Z","runID":"20260928T131912Z-cc90d5bd","#
      + #""schemaVersion":1,"#
      + #""tiers":[{"durationMilliseconds":282,"testCounts":null,"tier":"T0","verdict":"GREEN"}],"#
      + #""verdict":"GREEN"}"#
  }

  @Test(
    "a history line's base decodes and encodes back unchanged, and a line without one decodes as nil — catches the base a gate measured from lost on a rewrite, or a missing one read as a default"
  )
  func baseRoundTrips() throws {
    let surface = "5c1e0a9b7d3f2e1c0b9a8f7e6d5c4b3a2f1e0d9c"
    let data = Data((Self.line(base: surface) + "\n" + Self.line(base: nil) + "\n").utf8)

    let decoded = RunHistoryJSON.decode(data)
    let first = try #require(decoded.records.first)
    let reencoded = RunHistoryJSON.decode(try RunHistoryJSON.encodeLine(first))

    #expect(decoded.invalidLines == 0)
    #expect(decoded.records.map(\.base) == [surface, nil])
    #expect(reencoded.records.map(\.base) == [surface])
  }
}

import Foundation
import SwiftGateDomain
import Testing

@Suite("the store section counts rolled-up test results from their segment indexes")
struct StoreSectionRolledUpTests {
  static func input(results: Int, rolledUp: EventStoreFacts.RolledUpTests?) -> EventSummaryInput {
    let events =
      [TestRollupTests.gate("a", tree: nil, dirty: nil)]
      + (0..<results).map { TestRollupTests.result("T/case\($0)", .passed, run: "a") }
    return EventSummaryInput(
      events: events.map { StoredEvent(event: $0, bytes: 10) }, query: EventQuery(),
      store: EventStoreFacts(
        streams: [
          EventStoreFacts.Stream(stream: .test, activeBytes: 0, sealedSegments: 2, sealedBytes: 9)
        ], stores: 1, rolledUpTests: rolledUp),
      damage: [], files: GateTimeSectionTests.NoFiles(), now: TestRollupTests.start)
  }

  static let note =
    "test.result counted from 2 sealed segment indexes; with --since, whole segments"

  @Test(
    "rolled-up lines and bytes are added to the active results' and to the header's event count, with a note saying where they came from — catches sealed results missing from the store's size"
  )
  func rolledUpCountsJoinActiveOnes() throws {
    let input = Self.input(
      results: 2, rolledUp: EventStoreFacts.RolledUpTests(segments: 2, lines: 100, bytes: 5_000))

    let report = try #require(StoreSection().summarize(input))

    let bytes = try #require(
      report.metrics.first { $0.name == "bytes" && $0.group == ["test.result"] })
    #expect(bytes.value == 5_020)
    #expect(bytes.n == 102)
    #expect(report.lines.contains("test.result: 5020 bytes (n=102)"))
    #expect(report.lines.contains(Self.note))
    #expect(EventSummary.make(input).events == 103)
  }

  @Test(
    "with no active result the rolled-up ones still get a test.result line — catches a kind printed only when an event of it was decoded"
  )
  func rolledUpAloneIsListed() throws {
    let input = Self.input(
      results: 0, rolledUp: EventStoreFacts.RolledUpTests(segments: 2, lines: 40, bytes: 900))

    let report = try #require(StoreSection().summarize(input))

    #expect(report.lines.contains("test.result: 900 bytes (n=40)"))
    #expect(report.lines.contains(Self.note))
  }
}

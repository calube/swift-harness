import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("events summary: caches")
struct CachesSectionTests {
  static let start = GateTimeSectionTests.start

  static func lookup(
    _ id: String, _ cache: CacheName, _ outcome: CacheLookupOutcome, key: String = "k1",
    answer: String? = nil, reason: EvidenceCacheTombstoneReason? = nil, at seconds: Double
  ) -> HarnessEvent {
    HarnessEvent(
      eventID: id, time: start.addingTimeInterval(seconds), source: HarnessEventSource(route: nil),
      payload: .cacheLookup(
        CacheLookupEvent(
          cache: cache, outcome: outcome, keyHash: key, answerHash: answer,
          tombstoneReason: reason)))
  }

  static func report(_ events: [HarnessEvent]) throws -> EventSummarySectionReport {
    try #require(CachesSection().summarize(GateTimeSectionTests.input(events)))
  }

  static let invisibleNote =
    "a stale hit that no later store replaces stays invisible, so 0 stale keys doesn't mean no stale hits"

  @Test(
    "1 key that stored 2 different answers is 1 stale key, the hits that served the replaced answer are counted, and the invisible-stale note is printed — catches a stale key missed, a stale hit left uncounted, or the note dropped"
  )
  func staleKey() throws {
    let report = try Self.report([
      Self.lookup("1", .manifest, .miss, at: 0),
      Self.lookup("2", .manifest, .store, answer: "a", at: 1),
      Self.lookup("3", .manifest, .hit, answer: "a", at: 2),
      Self.lookup("4", .manifest, .hit, answer: "a", at: 3),
      Self.lookup("5", .manifest, .store, answer: "b", at: 4),
      Self.lookup("6", .manifest, .hit, answer: "b", at: 5),
      Self.lookup("7", .manifest, .store, key: "k2", answer: "c", at: 6),
      Self.lookup("8", .manifest, .hit, key: "k2", answer: "c", at: 7),
    ])

    let stale = try #require(GateTimeSectionTests.metric(report, "stale-keys", ["manifest"]))
    #expect(stale.value == 1)
    #expect(stale.n == 2)
    let replaced = try #require(
      GateTimeSectionTests.metric(report, "replaced-answer-hits", ["manifest"]))
    #expect(replaced.value == 2)
    #expect(replaced.n == 4)
    #expect(report.lines.contains("  stale keys: 1 of 2 keys (n=2)"))
    #expect(report.lines.contains(Self.invisibleNote))

    let many = try Self.report(
      (0..<11).flatMap { index in
        ["a", "b"].map { answer in
          Self.lookup(
            "\(index)\(answer)", .manifest, .store, key: "key\(index)", answer: answer,
            at: Double(index))
        }
      })
    #expect(GateTimeSectionTests.metric(many, "stale-keys", ["manifest"])?.value == 11)
    #expect(many.lines.contains("    and 1 more"))
    #expect(many.lines.count { $0.hasPrefix("    key ") } == 10)
  }

  @Test(
    "the hit rate is hits over hits and misses with that count as n, per cache, and there is no rate for a cache with only stores — catches stores counted as lookups, caches pooled, or a rate without its n"
  )
  func hitRateCarriesN() throws {
    let report = try Self.report([
      Self.lookup("1", .evidenceClaim, .miss, at: 0),
      Self.lookup("2", .evidenceClaim, .store, answer: "a", at: 1),
      Self.lookup("3", .evidenceClaim, .hit, answer: "a", at: 2),
      Self.lookup("4", .evidenceClaim, .hit, answer: "a", at: 3),
      Self.lookup("5", .evidenceClaim, .hit, answer: "a", at: 4),
      Self.lookup("6", .evidenceClaim, .tombstone, reason: .refuted, at: 5),
      Self.lookup("7", .evidenceVerdict, .store, answer: "v", at: 6),
    ])

    let rate = try #require(GateTimeSectionTests.metric(report, "hit-rate", ["evidence-claim"]))
    #expect(rate.value == 0.75)
    #expect(rate.n == 4)
    #expect(rate.unit == .share)
    #expect(GateTimeSectionTests.metric(report, "tombstones", ["evidence-claim"])?.value == 1)
    #expect(GateTimeSectionTests.metric(report, "hit-rate", ["evidence-verdict"]) == nil)
    #expect(GateTimeSectionTests.metric(report, "stores", ["evidence-verdict"])?.value == 1)
    #expect(GateTimeSectionTests.metric(report, "hit-rate", ["manifest"]) == nil)
    #expect(
      report.lines.contains(
        "evidence-claim: hit rate 0.75 (3 hits of 4 lookups, n=4); 1 store, 1 tombstone (refuted 1)"
      ))
    #expect(report.lines.contains("evidence-verdict: no lookups yet; 1 store, 0 tombstones"))

    #expect(CachesSection().summarize(GateTimeSectionTests.input([])) == nil)
  }

  @Test(
    "on cache events a worktree's gate runs wrote, the manifest cache hits 8 of 10 lookups with no stale key of 2 and still prints the invisible-stale note — catches the reader misreading real lines"
  )
  func realCacheEvents() throws {
    let events = try HarnessEventJSON.decode(Fixture.data("Events/cache.jsonl")).events
    #expect(events.count == 12)

    let report = try Self.report(events)

    let rate = try #require(GateTimeSectionTests.metric(report, "hit-rate", ["manifest"]))
    #expect(rate.value == 0.8)
    #expect(rate.n == 10)
    #expect(GateTimeSectionTests.metric(report, "stale-keys", ["manifest"])?.value == 0)
    #expect(GateTimeSectionTests.metric(report, "stale-keys", ["manifest"])?.n == 2)
    #expect(report.lines.contains(Self.invisibleNote))
  }
}

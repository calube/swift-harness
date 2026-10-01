import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("events summary: wrong gates")
struct WrongGatesSectionTests {
  static let tree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
  static let pushTiers = [
    GateRunTier(tier: .t0, verdict: .green, milliseconds: 10),
    GateRunTier(tier: .t1, verdict: .green, milliseconds: 20),
  ]

  static func run(
    _ id: String, _ verdict: Verdict, command: String? = "check push", treeHash: String? = tree,
    dirty: Bool? = false, tiers: [GateRunTier] = pushTiers, rules: [String: Int] = [:],
    paths: [String] = [], allowances: [String: Int] = [:], at seconds: Double
  ) -> HarnessEvent {
    HarnessEvent(
      eventID: id, time: GateTimeSectionTests.start.addingTimeInterval(seconds), runID: id,
      source: HarnessEventSource(route: .check, tier: .push),
      payload: .gateRun(
        GateRunEvent(
          command: command, verdict: verdict, milliseconds: 30, treeHash: treeHash, dirty: dirty,
          tiers: tiers, ruleCounts: rules, findingPaths: paths, findingPathsTruncated: false,
          allowanceCounts: allowances, testCounts: nil)))
  }

  static func metric(_ report: EventSummarySectionReport, _ name: String) -> EventSummaryMetric? {
    report.metrics.first { $0.name == name && $0.group.isEmpty }
  }

  @Test(
    "a clean RED then GREEN on the same tree is 1 flip that marks the rules the GREEN no longer reports as overturned — catches a flip missed or a rule both runs report blamed"
  )
  func sameTreeRedThenGreenIsAFlip() throws {
    let events = [
      Self.run(
        "red", .red, rules: ["t1.failed": 2, "coverage.summary": 1], paths: ["Tests/ATests.swift"],
        at: 0),
      Self.run("green", .green, rules: ["coverage.summary": 1], at: 10),
    ]

    let found = WrongGateFindings(events: events)

    #expect(
      found.flips == [
        GateFlip(
          command: "check push", tiers: [.t0, .t1], treeHash: Self.tree, earlierRunID: "red",
          earlierVerdict: .red, laterRunID: "green", laterVerdict: .green,
          overturnedRules: ["t1.failed"])
      ])
    #expect(found.comparedPairs == 1)
    #expect(found.cleanRuns == 2)
    #expect(found.dirtyRuns == 0)

    let report = try #require(
      WrongGatesSection().summarize(GateTimeSectionTests.input(events)))
    #expect(Self.metric(report, "flips")?.value == 1)
    #expect(Self.metric(report, "flips")?.n == 1)
    #expect(Self.metric(report, "flip-rate")?.value == 1)
    #expect(Self.metric(report, "flip-rate")?.n == 1)
    #expect(report.lines.contains { $0.contains("overturned t1.failed") && $0.contains("red") })
  }

  @Test(
    "a RED then GREEN where either run is dirty, or has no tree hash, isn't a flip — catches dirty runs compared"
  )
  func dirtyRunsAreNeverCompared() {
    let red = ["t1.failed": 1]
    let pairs: [[HarnessEvent]] = [
      [
        Self.run("r", .red, rules: red, at: 0),
        Self.run("g", .green, treeHash: nil, dirty: true, at: 10),
      ],
      [
        Self.run("r", .red, treeHash: nil, dirty: true, rules: red, at: 0),
        Self.run("g", .green, treeHash: nil, dirty: true, at: 10),
      ],
      [
        Self.run("r", .red, dirty: true, rules: red, at: 0),
        Self.run("g", .green, at: 10),
      ],
      [
        Self.run("r", .red, dirty: nil, rules: red, at: 0),
        Self.run("g", .green, dirty: nil, at: 10),
      ],
    ]
    for events in pairs {
      let found = WrongGateFindings(events: events)
      #expect(found.flips.isEmpty)
      #expect(found.comparedPairs == 0)
      #expect(found.cleanRuns + found.dirtyRuns == 2)
    }
  }

  @Test(
    "clean runs with different verdicts on different trees, commands or tier lists aren't flips — catches runs compared across keys"
  )
  func differentKeysAreNotFlips() {
    let events = [
      Self.run("a", .red, at: 0),
      Self.run("b", .green, treeHash: "other", at: 1),
      Self.run("c", .green, command: "check pre-commit", at: 2),
      Self.run(
        "d", .green, tiers: [GateRunTier(tier: .t0, verdict: .green, milliseconds: 1)], at: 3),
    ]
    let found = WrongGateFindings(events: events)
    #expect(found.flips.isEmpty)
    #expect(found.comparedPairs == 0)
    #expect(found.cleanRuns == 4)
  }

  @Test(
    "a GREEN then RED on 1 tree is a flip that overturns nothing — catches only one direction counted"
  )
  func greenThenRedFlipsWithoutOverturning() {
    let found = WrongGateFindings(events: [
      Self.run("g", .green, at: 0), Self.run("r", .red, rules: ["t1.failed": 1], at: 1),
      Self.run("r2", .red, rules: ["t1.failed": 1], at: 2),
    ])
    #expect(found.flips.count == 1)
    #expect(found.flips.first?.overturnedRules == [])
    #expect(found.comparedPairs == 2)
  }

  @Test(
    "a RED for R naming P, then a run with R's allowances up by 1 and P gone, overturns R; up by 1 with P still named doesn't — catches a waived finding counted as fixed, or a fixed one as waived"
  )
  func allowOverturnsARed() throws {
    let waived = [
      Self.run(
        "red", .red, treeHash: nil, dirty: true, rules: ["det.uuid-init": 1],
        paths: ["Sources/A.swift"], allowances: ["det.uuid-init": 2], at: 0),
      Self.run(
        "after", .green, treeHash: nil, dirty: true, allowances: ["det.uuid-init": 3], at: 10),
    ]
    let found = WrongGateFindings(events: waived)
    #expect(
      found.allowOverturns == [
        AllowOverturn(
          command: "check push", rule: "det.uuid-init", paths: ["Sources/A.swift"],
          redRunID: "red", laterRunID: "after")
      ])
    #expect(found.followedReds == 1)
    let report = try #require(
      WrongGatesSection().summarize(GateTimeSectionTests.input(waived)))
    #expect(Self.metric(report, "allow-overturns")?.value == 1)
    #expect(Self.metric(report, "allow-overturns")?.n == 1)

    let stillNamed = [
      waived[0],
      Self.run(
        "after", .red, treeHash: nil, dirty: true, rules: ["det.uuid-init": 1],
        paths: ["Sources/A.swift"], allowances: ["det.uuid-init": 3], at: 10),
    ]
    #expect(WrongGateFindings(events: stillNamed).allowOverturns.isEmpty)

    let noNewAllowance = [
      waived[0],
      Self.run("after", .green, allowances: ["det.uuid-init": 2], at: 10),
    ]
    #expect(WrongGateFindings(events: noNewAllowance).allowOverturns.isEmpty)
  }

  @Test(
    "on this repo's recorded push runs, all dirty and with a RED then GREEN, nothing flips and every run counts as dirty — catches runs with no tree hash matched to each other"
  )
  func realGateEvents() throws {
    let events = try HarnessEventJSON.decode(Fixture.data("Events/gate.jsonl")).events

    let found = WrongGateFindings(events: events)

    #expect(found.flips.isEmpty)
    #expect(found.dirtyRuns == 7)
    #expect(found.cleanRuns == 0)
    #expect(found.followedReds == 1)
    let report = try #require(
      WrongGatesSection().summarize(GateTimeSectionTests.input(events)))
    #expect(Self.metric(report, "flips")?.n == 0)
    #expect(Self.metric(report, "flip-rate") == nil)
    #expect(Self.metric(report, "dirty-runs")?.value == 7)
  }
}

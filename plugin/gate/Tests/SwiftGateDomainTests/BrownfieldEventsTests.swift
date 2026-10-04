import Foundation
import SwiftGateDomain
import Testing

@Suite("brownfield events")
struct BrownfieldEventsTests {
  private func line(kind: String, payload: String) -> Data {
    Data(
      ("{\"eventID\":\"e1\",\"kind\":\"\(kind)\",\"payload\":\(payload),"
        + "\"schemaVersion\":1,\"source\":{},\"time\":\"2026-10-03T12:00:00.000Z\"}\n").utf8)
  }

  @Test(
    "a warmup.run line decodes, and cache = \"lukewarm\" fails naming cache — catches an open cache value"
  )
  func warmupCacheIsClosed() throws {
    let warm = try HarnessEventJSON.decode(
      line(
        kind: "warmup.run",
        payload:
          "{\"area\":\"api\",\"cache\":\"warm\",\"ms\":1200,\"outcome\":\"not-installed\",\"step\":\"generate\"}"
      ))
    #expect(
      warm.events.map(\.payload) == [
        .warmupRun(
          WarmupRunEvent(
            area: "api", step: .generate, milliseconds: 1200, cache: .warm, outcome: .notInstalled))
      ])
    do {
      _ = try HarnessEventJSON.decode(
        line(
          kind: "warmup.run",
          payload:
            "{\"area\":\"api\",\"cache\":\"lukewarm\",\"ms\":1,\"outcome\":\"passed\",\"step\":\"build\"}"
        ))
      Issue.record("cache = lukewarm decoded")
    } catch {
      #expect(error.description.contains("cache"), "\(error)")
    }
  }

  @Test("a discover.run event round-trips with its counts under ms — catches a dropped payload")
  func discoverRunRoundTrips() throws {
    let event = HarnessEvent(
      eventID: "e2", time: Date(timeIntervalSince1970: 1_790_000_000),
      source: HarnessEventSource(route: nil),
      payload: .discoverRun(
        DiscoverRunEvent(
          milliseconds: 1800, areas: 4, languages: [.python, .javascript, .swift], found: 9,
          guessed: 2, missing: 1, edited: 1)))
    let data = try HarnessEventJSON.encodeLine(event)
    #expect(String(decoding: data, as: UTF8.self).contains("\"kind\":\"discover.run\""))
    #expect(String(decoding: data, as: UTF8.self).contains("\"ms\":1800"))
    #expect(try HarnessEventJSON.decode(data).events == [event])
  }

  @Test(
    "a gate.step carries its area, and each new step spells its design name — catches an area dropped from the event"
  )
  func gateStepCarriesArea() throws {
    let steps: [GateStep] = [
      .areaTest, .areaLint, .areaBuild, .neutral, .baseline, .xcodeMembership,
    ]
    for step in steps {
      let event = GateStepEvent(
        GateStepTiming(
          step: step, tier: nil, milliseconds: 5, verdict: .green, derivedData: .none, area: "api"))
      let object = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
      #expect(object["area"] as? String == "api", "\(step)")
      #expect(
        try JSONDecoder().decode(GateStepEvent.self, from: JSONEncoder().encode(event)) == event)
    }
    #expect(
      steps.map(\.rawValue) == [
        "area-test", "area-lint", "area-build", "neutral", "baseline", "xcode-membership",
      ])
  }

  @Test(
    "discover.run counts a proposal's areas, languages and each value by confidence — catches an orchestrator value counted as found"
  )
  func discoverRunCountsProposal() {
    func area(_ name: String, _ language: AreaLanguage, _ commands: [AreaStep: Confidence])
      -> ProposedArea
    {
      ProposedArea(
        name: name, root: name, language: language, kind: .node, source: "\(name)/package.json",
        commands: commands.mapValues { Sourced(value: "cmd", source: "f", confidence: $0) },
        missing: [.e2e: "none configured", .build: "none configured"], testGlobs: [], xcode: nil,
        generatedProjectTracked: nil)
    }
    let proposal = DiscoverProposal(
      head: "abc",
      areas: [
        area("web", .typescript, [.test: .found, .lint: .guessed]),
        area("api", .python, [.test: .found, .testFiles: .orchestrator]),
        area("docs", .typescript, [.build: .guessed]),
      ],
      dirty: [])
    #expect(
      DiscoverRunEvent(proposal: proposal, milliseconds: 40, edited: 1)
        == DiscoverRunEvent(
          milliseconds: 40, areas: 3, languages: [.typescript, .python], found: 2, guessed: 2,
          missing: 6, edited: 1))
  }
}

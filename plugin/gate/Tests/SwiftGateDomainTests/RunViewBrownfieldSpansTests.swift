import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

private let buildRun = "20261004T045528Z-58d28c78"

/// The `brownfield` stream a real `discover --apply` and `warmup` wrote: 1 `discover.run`, then
/// 2 areas' `build` and `test` steps.
private func captured() throws -> [HarnessEvent] {
  try HarnessEventJSON.decode(
    try Fixture.data("RunView/brownfield-prebuild/events/brownfield.jsonl")
  ).events
}

private func time(_ text: String) throws -> Date {
  try Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
}

@Suite("RunView brownfield spans")
struct RunViewBrownfieldSpansTests {
  @Test(
    "a captured warm-up yields 1 span per area and step, laid end to end before the area's event and nested in the run span — catches steps drawn overlapping or left out of the run"
  )
  func warmupSpans() throws {
    let launched = try time("2026-10-04T09:19:55.000Z")
    let view = RunViewBuilder.build(
      RunViewInput(buildRun: buildRun, events: try captured(), launchedAt: launched))
    let warmups = view.spans.filter { $0.phase == .warmup }.sorted { $0.id < $1.id }
    #expect(
      warmups.map(\.id) == [
        "warmup:api:build:D1F8DF10-E549-4BB7-B373-C512001D80FB",
        "warmup:api:test:C979AA9E-888E-48A0-BA18-674F20F25556",
        "warmup:web:build:D12A65D1-CA4C-41A0-856D-9FFC1C952B85",
        "warmup:web:test:1A4D1A7F-7A35-46DB-8B81-5B275EB95669",
      ])
    #expect(warmups.allSatisfy { $0.parent == "run" && $0.outcome == .ok && $0.approximate })

    let apiEnd = try time("2026-10-04T09:19:56.935Z")
    let apiTest = warmups[1]
    let apiBuild = warmups[0]
    #expect(apiTest.end == apiEnd)
    #expect(apiTest.start == apiEnd.addingTimeInterval(-0.489))
    #expect(apiBuild.end == apiTest.start)
    #expect(apiBuild.start == apiTest.start.addingTimeInterval(-0.505))
    #expect(warmups[2].end == warmups[3].start)
    #expect(warmups[3].end == (try time("2026-10-04T09:19:57.042Z")))

    let run = try #require(view.spans.first { $0.id == "run" })
    #expect(run.start == launched)
    #expect(view.run.startedAt == launched)
  }

  @Test(
    "a discover.run becomes a discover span ending at its event and starting its ms earlier, under the run — catches discovery missing from a brownfield run"
  )
  func discoverSpan() throws {
    let view = RunViewBuilder.build(
      RunViewInput(
        buildRun: buildRun, events: try captured(),
        launchedAt: try time("2026-10-04T09:19:55.000Z")))
    let discover = view.spans.filter { $0.phase == .discover }
    let end = try time("2026-10-04T09:19:55.859Z")
    #expect(
      discover == [
        RunView.Span(
          id: "discover:79C09BCC-4237-48CC-9C79-73500EB39EC8", parent: "run", phase: .discover,
          start: end.addingTimeInterval(-0.07), end: end, outcome: .ok)
      ])
  }

  @Test(
    "a warm-up step that failed ends red and one dropped or not installed ends abandoned — catches a failed warm-up drawn as passed"
  )
  func warmupOutcomes() throws {
    let at = try time("2026-10-04T09:00:00.000Z")
    let events = [WarmupOutcome.failed, .dropped, .notInstalled].enumerated().map {
      index, outcome in
      HarnessEvent(
        eventID: "e\(index)", time: at.addingTimeInterval(Double(index)),
        source: HarnessEventSource(route: nil),
        payload: .warmupRun(
          WarmupRunEvent(
            area: "a\(index)", step: .test, milliseconds: 100, cache: .warm, outcome: outcome)))
    }
    let view = RunViewBuilder.build(
      RunViewInput(buildRun: buildRun, events: events, launchedAt: at.addingTimeInterval(-1)))
    #expect(
      view.spans.filter { $0.phase == .warmup }.map(\.outcome) == [.red, .abandoned, .abandoned])
  }
}

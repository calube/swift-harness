import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// A brownfield clone's common dir in a temp directory: the captured build run's plan state, its
/// `build` and `gate` streams, and the captured pre-build streams, whose spans name that plan's
/// slug. Nothing here reads or writes this checkout's own stores or plan state.
private struct PrebuildClone {
  static let captured = Fixture.gateDirectory.appending(
    path: "Tests/Fixtures/RunView", directoryHint: .isDirectory)
  static let buildRun = "20261004T045528Z-58d28c78"
  static let plan = "2026-10-03-counter-reset-and-floor"

  let parent: URL
  let common: URL
  var planDirectory: URL {
    common.appending(path: "swift-harness/plans/\(Self.plan)", directoryHint: .isDirectory)
  }
  var state: StateRoot { .gitDir(common) }

  /// `launched` is when `swiftgate run` started the plan, written as its `clock.json`.
  init(launched: Date) throws {
    parent = FileManager.default.temporaryDirectory.appending(
      path: "run-view-prebuild-\(UUID().uuidString)", directoryHint: .isDirectory)
    common = parent.appending(path: "app/.git", directoryHint: .isDirectory)
    let run = Self.captured.appending(path: "build-run-1", directoryHint: .isDirectory)
    let runDirectory = planDirectory.appending(
      path: "build/\(Self.buildRun)", directoryHint: .isDirectory)
    let events = state.url(RunLayout.eventsDirectory, directoryHint: .isDirectory)
    for directory in [runDirectory.appending(path: "returns"), events] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let copies: [(URL, URL)] = [
      (run.appending(path: "ledger.json"), planDirectory.appending(path: "ledger.json")),
      (run.appending(path: "plan.json"), planDirectory.appending(path: "plan.json")),
      (run.appending(path: "plan.md"), planDirectory.appending(path: "spec-page.md")),
      (run.appending(path: "run.json"), runDirectory.appending(path: "run.json")),
      (run.appending(path: "ledger-events.jsonl"), runDirectory.appending(path: "events.jsonl")),
      (run.appending(path: "events/build.jsonl"), events.appending(path: "build.jsonl")),
      (run.appending(path: "events/gate.jsonl"), events.appending(path: "gate.jsonl")),
      (
        Self.captured.appending(path: "brownfield-prebuild/events/brownfield.jsonl"),
        events.appending(path: "brownfield.jsonl")
      ),
      (
        Self.captured.appending(path: "brownfield-prebuild/events/span.jsonl"),
        events.appending(path: "span.jsonl")
      ),
    ]
    for (source, target) in copies {
      try FileManager.default.copyItem(at: source, to: target)
    }
    try Self.writeClock(launched, in: planDirectory)
  }

  static func writeClock(_ started: Date, in directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try RunClock(
      started: started, spec: "/spec.md", origin: "/spec.md", specSource: .copied,
      planBranch: "swift-harness/\(directory.lastPathComponent)",
      base: String(repeating: "a", count: 40)
    ).encoded().write(to: directory.appending(path: RunClock.fileName))
  }

  var reader: RunViewReader {
    RunViewReader(commonDirectory: common, stateRoot: state, profile: .brownfield)
  }

  func remove() { try? FileManager.default.removeItem(at: parent) }
}

private func time(_ text: String) throws -> Date {
  try Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
}

/// Each span's chain of parents, up to the first span with none.
private func ancestry(of span: RunView.Span, in view: RunView) -> [String] {
  var chain: [String] = []
  var parent = span.parent
  while let id = parent, !chain.contains(id) {
    chain.append(id)
    parent = view.spans.first { $0.id == id }?.parent
  }
  return chain
}

@Suite("run view reader: a brownfield run's pre-build phases")
struct RunViewReaderPrebuildTests {
  @Test(
    "the run skill's slug-tagged spans, discovery and the warm-up fold into the plan's build run, so 1 view holds the run from spec-read to final under its run span — catches pre-build spans landing in a separate or orphan run"
  )
  func foldsIntoTheBuildRun() throws {
    // Before the captured build run's record starts, so the launch opens the whole run.
    let launched = try time("2026-10-04T04:55:00.000Z")
    let clone = try PrebuildClone(launched: launched)
    defer { clone.remove() }

    #expect(clone.reader.newestBuildRun() == PrebuildClone.buildRun)
    let input = try clone.reader.read(buildRun: PrebuildClone.buildRun)
    #expect(input.launchedAt == launched)
    #expect(input.damage.isEmpty, "\(input.damage)")
    let view = RunViewBuilder.build(input)

    let phases = view.spans.map(\.phase)
    for phase: RunView.Phase in [.specRead, .discover, .explore, .plan, .contract, .final] {
      #expect(phases.filter { $0 == phase }.count == 1, "\(phase)")
    }
    #expect(phases.filter { $0 == .warmup }.count == 4)
    #expect(view.run.startedAt == launched)
    for span in view.spans where span.id != "run" {
      let chain = ancestry(of: span, in: view)
      #expect(chain.last == "run", "\(span.id) sits under \(chain), not the run span")
      #expect(span.start >= launched, "\(span.id) starts before the run")
    }
    #expect(!view.damage.contains { $0.reason.contains("never") }, "\(view.damage)")
  }

  @Test(
    "discovery and a warm-up from before the plan launched, or after the next plan launched, stay out while the slug's spans still fold in — catches another run's warm-up drawn in this one"
  )
  func keepsOnlyThisLaunch() throws {
    // Launched after the discover.run and between the 2 areas' warm-ups.
    let clone = try PrebuildClone(launched: try time("2026-10-04T09:19:56.000Z"))
    defer { clone.remove() }
    let other = clone.common.appending(
      path: "swift-harness/plans/2026-10-04-other", directoryHint: .isDirectory)
    try PrebuildClone.writeClock(try time("2026-10-04T09:19:57.000Z"), in: other)

    let view = RunViewBuilder.build(try clone.reader.read(buildRun: PrebuildClone.buildRun))
    #expect(view.spans.filter { $0.phase == .discover }.isEmpty)
    #expect(
      view.spans.filter { $0.phase == .warmup }.map(\.id).sorted() == [
        "warmup:api:build:D1F8DF10-E549-4BB7-B373-C512001D80FB",
        "warmup:api:test:C979AA9E-888E-48A0-BA18-674F20F25556",
      ])
    #expect(view.spans.filter { $0.phase == .specRead }.count == 1)
  }

  @Test(
    "a clock.json that doesn't decode is a damage row naming it, and the slug's spans still fold in — catches a silent run with no launch"
  )
  func undecodableClockIsDamage() throws {
    let clone = try PrebuildClone(launched: try time("2026-10-04T04:55:00.000Z"))
    defer { clone.remove() }
    try Data("{\"started\": 1}\n".utf8).write(
      to: clone.planDirectory.appending(path: RunClock.fileName))

    let input = try clone.reader.read(buildRun: PrebuildClone.buildRun)
    #expect(input.launchedAt == nil)
    #expect(
      input.damage.map(\.source) == ["swift-harness/plans/\(PrebuildClone.plan)/clock.json"])
    let view = RunViewBuilder.build(input)
    #expect(view.spans.filter { $0.phase == .specRead }.count == 1)
    #expect(view.spans.filter { $0.phase == .warmup }.isEmpty)
  }

  @Test(
    "a later build run of the same plan keeps none of the plan's pre-build phases — catches every build run of a plan redrawing its spec-read and warm-up"
  )
  func laterBuildRunKeepsNone() throws {
    let clone = try PrebuildClone(launched: try time("2026-10-04T09:19:55.000Z"))
    defer { clone.remove() }
    let later = "20261004T100000Z-0000beef"
    let directory = clone.planDirectory.appending(
      path: "build/\(later)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data().write(to: directory.appending(path: "events.jsonl"))

    let input = try clone.reader.read(buildRun: later)
    #expect(input.launchedAt == nil)
    let phases = Set(RunViewBuilder.build(input).spans.map(\.phase))
    #expect(phases.isDisjoint(with: [.specRead, .explore, .plan, .contract, .discover, .warmup]))
  }
}

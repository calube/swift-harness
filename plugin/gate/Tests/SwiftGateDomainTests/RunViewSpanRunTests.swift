import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// The build run under `Fixtures/RunView/build-run-2`, captured once the skills, the task workflow,
/// prove and ingest record spans, proofs and tool summaries, read as the reader hands it over.
private struct SpanRun {
  static let directory = "RunView/build-run-2"

  let ledger: Ledger
  let view: RunView

  init() throws {
    let ledger = try LedgerJSON.decode(try Fixture.data("\(Self.directory)/ledger.json"))
    let record = try BuildRunJSON.decode(try Fixture.data("\(Self.directory)/run.json"))
    let log = BuildEventJSON.decode(try Fixture.data("\(Self.directory)/ledger-events.jsonl"))
    var returns: [String: TaskReturn] = [:]
    for name in try Self.files(in: "returns", suffix: ".json") {
      let taskReturn = try TaskReturnJSON.decode(try Fixture.data(name))
      returns[taskReturn.task] = taskReturn
    }
    var streams = try Self.files(in: "events", suffix: ".jsonl")
    for store in try Self.entries(in: "events/imported") where !store.hasPrefix(".") {
      streams += try Self.files(in: "events/imported/\(store)", suffix: ".jsonl")
    }
    var events: [HarnessEvent] = []
    for stream in streams {
      events += try HarnessEventJSON.decode(try Fixture.data(stream)).events
    }
    guard case .parsed(let page) = SpecPage.parse(try Fixture.text("\(Self.directory)/plan.md"))
    else {
      throw SpanRunError.specPageMalformed
    }
    let join = BuildJoin.Run(
      plan: record.plan, runID: record.runID,
      writeSets: Dictionary(uniqueKeysWithValues: ledger.tasks.map { ($0.id, $0.writeSet) }),
      returns: returns, events: log.events, record: record)
    self.ledger = ledger
    self.view = RunViewBuilder.build(
      RunViewInput(
        buildRun: record.runID, events: events.filter { $0.time >= record.startedAt },
        join: join, ledger: ledger, requirements: RunViewRequirements.from(specPage: page)))
  }

  private static func entries(in relative: String) throws -> [String] {
    try FileManager.default.contentsOfDirectory(
      atPath: Fixture.directory.appending(path: "\(directory)/\(relative)").path
    ).sorted()
  }

  private static func files(in relative: String, suffix: String) throws -> [String] {
    try entries(in: relative).filter { $0.hasSuffix(suffix) }.map {
      "\(directory)/\(relative)/\($0)"
    }
  }
}

private enum SpanRunError: Error {
  case specPageMalformed
}

private func contains(_ outer: RunView.Span, _ inner: RunView.Span) -> Bool {
  guard inner.start >= outer.start else { return false }
  guard let outerEnd = outer.end else { return true }
  guard let innerEnd = inner.end else { return false }
  return innerEnd <= outerEnd
}

@Suite("run view of a build captured with spans")
struct RunViewSpanRunTests {
  @Test(
    "the build's final phase and the ship report each hold 1 ended span inside the run — catches a phase the skills stopped marking"
  )
  func phaseSpans() throws {
    let view = try SpanRun().view
    let run = try #require(view.spans.first { $0.phase == .run })
    for phase in [RunView.Phase.final, .ship] {
      let spans = view.spans.filter { $0.phase == phase }
      #expect(spans.count == 1, "\(phase)")
      let span = try #require(spans.first)
      #expect(span.parent == run.id, "\(phase)")
      #expect(span.outcome == .ok, "\(phase)")
      #expect(contains(run, span), "\(phase)")
    }
  }

  @Test(
    "every task's worker stage nests inside that task's span — catches stage spans drawn flat under the run or under another task"
  )
  func workerStagesNest() throws {
    let captured = try SpanRun()
    let view = captured.view
    #expect(captured.ledger.tasks.count == 3)
    for task in captured.ledger.tasks {
      let taskSpan = try #require(view.spans.first { $0.phase == .task && $0.task == task.id })
      let workers = view.spans.filter { $0.phase == .worker && $0.task == task.id }
      #expect(workers.count == 1, "\(task.id)")
      for worker in workers {
        #expect(worker.parent == taskSpan.id, "\(task.id)")
        #expect(contains(taskSpan, worker), "\(task.id)")
        #expect(worker.end != nil, "\(task.id)")
      }
    }
  }

  @Test(
    "each worker span carries the tool calls its agent made — catches tool windows attributed to the task or the run instead of the stage"
  )
  func workerTools() throws {
    let view = try SpanRun().view
    let workers = view.spans.filter { $0.phase == .worker }
    #expect(workers.count == 3)
    for worker in workers {
      let tools = try #require(worker.tools, "\(worker.id)")
      #expect(tools.calls.contains { $0.tool == .bash && $0.count > 0 }, "\(worker.id)")
    }
  }

  @Test(
    "the final gate's prove results land under that gate, each proven — catches a prove result dropped between the test stream and the view"
  )
  func finalGateProofs() throws {
    let view = try SpanRun().view
    let finalGate = try #require(view.gates.first { $0.command == "check ready" })
    let proofs = view.proofs.filter { $0.gateRun == finalGate.runID }
    #expect(
      Set(proofs.map(\.test)) == [
        "CounterCoreTests.CounterFeatureTests/resetAfterIncrementsShowsZero",
        "CounterCoreTests.CounterFeatureTests/resetClearsFact",
        "CounterCoreTests.CounterFeatureTests/decrementAtZeroStaysZero",
      ])
    #expect(proofs.allSatisfy { $0.outcome == .proven })
    #expect(view.proofs.count == proofs.count)
  }

  @Test(
    "the captured run folds with no damage: every span started and ended once and every parent exists — catches an orphan or twice-ended span"
  )
  func noDamage() throws {
    let view = try SpanRun().view
    #expect(view.damage.isEmpty, "\(view.damage)")
    let ids = Set(view.spans.map(\.id))
    #expect(ids.count == view.spans.count)
    for span in view.spans {
      if let parent = span.parent { #expect(ids.contains(parent), "\(span.id)") }
    }
  }
}

import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

private let spanRun = "20261004T020000Z-5a1e0c0d"
private let planSpan = "c8bcf48355218740"
private let workerSpan = "0f8173d65d1118bf"

/// The span stream a real `events span` sequence wrote: a `plan` span around a `worker` span.
private func capturedSpans() throws -> [HarnessEvent] {
  try HarnessEventJSON.decode(try Fixture.data("RunView/span-sequence/span.jsonl")).events
}

private func gateEvents() throws -> [HarnessEvent] {
  try HarnessEventJSON.decode(try Fixture.data("RunView/build-run-1/events/gate.jsonl")).events
}

private func time(_ text: String) throws -> Date {
  try Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
}

@Suite("RunViewEmittedEvents")
struct RunViewEmittedEventsTests {
  @Test(
    "a span with a parent nests under it and a plan-stage span sits under the run — catches a flat fold"
  )
  func spansNest() throws {
    let view = RunViewBuilder.build(RunViewInput(buildRun: spanRun, events: try capturedSpans()))
    let plan = try #require(view.spans.first { $0.id == planSpan })
    let worker = try #require(view.spans.first { $0.id == workerSpan })
    #expect(plan.phase == .plan)
    #expect(plan.parent == "run")
    #expect(plan.outcome == .red)
    #expect(plan.start == (try time("2026-10-04T07:05:13.834Z")))
    #expect(plan.end == (try time("2026-10-04T07:05:15.201Z")))
    #expect(worker.phase == .worker)
    #expect(worker.parent == planSpan)
    #expect(worker.task == "counter-reset")
    #expect(worker.outcome == .ok)
    #expect(worker.end == (try time("2026-10-04T07:05:15.002Z")))
    #expect(view.damage.isEmpty)
  }

  @Test(
    "a span with a task and no parent sits under its task's span — catches a worker stage left at the run"
  )
  func taskSpanParent() throws {
    let start = try time("2026-10-04T07:00:00Z")
    let view = RunView(
      run: RunView.Run(id: spanRun, startedAt: start),
      spans: [
        RunView.Span(id: "run", phase: .run, start: start),
        RunView.Span(id: "task:counter-reset", parent: "run", phase: .task, start: start),
      ])
    let event = HarnessEvent(
      eventID: "w", time: start.addingTimeInterval(5), source: HarnessEventSource(route: nil),
      payload: .spanStart(
        SpanStartEvent(
          spanID: workerSpan, parentSpan: nil, phase: .worker, buildRun: spanRun,
          task: "counter-reset", role: .buildWorker)))
    let folded = RunViewEmittedEvents.fold([event], into: view)
    let worker = try #require(folded.spans.first { $0.id == workerSpan })
    #expect(worker.parent == "task:counter-reset")
    #expect(folded.spans.map(\.id) == ["run", "task:counter-reset", workerSpan])
  }

  @Test(
    "an unended span in a done run stays open and names itself in the footer — catches a span dropped or given a made-up end"
  )
  func neverEnded() throws {
    let starts = try capturedSpans().filter { $0.kind == .spanStart }
    let started = try #require(starts.first?.time)
    let done = RunView(run: RunView.Run(id: spanRun, startedAt: started, state: .done))
    let folded = RunViewEmittedEvents.fold(starts, into: done)
    let plan = try #require(folded.spans.first { $0.id == planSpan })
    #expect(plan.end == nil)
    #expect(plan.outcome == nil)
    #expect(
      folded.damage.map(\.reason).sorted() == [
        "plan span \(planSpan) never ended", "worker span \(workerSpan) never ended",
      ])

    let running = RunView(run: RunView.Run(id: spanRun, startedAt: started, state: .running))
    let live = RunViewEmittedEvents.fold(starts, into: running)
    #expect(live.spans.count == 2)
    #expect(live.damage.isEmpty)
  }

  @Test("an end with no start shows as damage — catches an orphan end silently dropped")
  func orphanEnd() throws {
    let ends = try capturedSpans().filter { $0.kind == .spanEnd }
    let view = RunView(run: RunView.Run(id: spanRun))
    let folded = RunViewEmittedEvents.fold(ends, into: view)
    #expect(folded.spans.isEmpty)
    #expect(folded.damage.count == 2)
    #expect(folded.damage.allSatisfy { $0.reason.hasSuffix("never started") })
  }

  @Test(
    "a second start or end of 1 span and a parent never started show as damage — catches the first span overwritten or nested under nothing"
  )
  func repeatedAndUnparented() throws {
    let captured = try capturedSpans()
    let workerStart = try #require(captured.first { $0.eventID.hasPrefix("1F48286F") })
    let workerEnd = try #require(captured.first { $0.eventID.hasPrefix("2264A9E6") })
    let later = workerEnd.time.addingTimeInterval(1)
    let restart = HarnessEvent(
      eventID: "again-start", time: later, source: HarnessEventSource(route: nil),
      payload: workerStart.payload)
    let reend = HarnessEvent(
      eventID: "again-end", time: later, source: HarnessEventSource(route: nil),
      payload: .spanEnd(SpanEndEvent(spanID: workerSpan, outcome: .red, milliseconds: 1)))
    let start = workerStart.time
    let view = RunView(
      run: RunView.Run(id: spanRun, startedAt: start),
      spans: [RunView.Span(id: "run", phase: .run, start: start)])
    let folded = RunViewEmittedEvents.fold(
      [workerStart, workerEnd, restart, reend], into: view)
    let workers = folded.spans.filter { $0.id == workerSpan }
    #expect(workers.count == 1)
    #expect(workers.first?.outcome == .ok)
    #expect(workers.first?.parent == "run")
    #expect(
      folded.damage.map(\.reason).sorted() == [
        "parent span \(planSpan) never started", "span \(workerSpan) ended twice",
        "span \(workerSpan) started twice",
      ])
  }

  @Test(
    "a prove.result lands under its gate run and that gate's task — catches a proof left unjoined"
  )
  func proofJoined() throws {
    let gateRun = "20261004T045901Z-e384a82a"
    let task = "counter-core-reset-and-decrement-floor"
    let gate = try #require(
      try gateEvents().first { $0.kind == .gateRun && $0.runID == gateRun })
    let view = RunView(
      run: RunView.Run(id: "b"),
      gates: [RunView.Gate(runID: gateRun, task: task, verdict: .green, milliseconds: 1)])
    let assertion = ProveAssertion(file: "Tests/CounterTests.swift", line: 12, kind: .expect)
    let proof = HarnessEvent(
      eventID: "p", parentID: gate.eventID, time: gate.time,
      source: HarnessEventSource(route: .check),
      payload: .proveResult(
        ProveResultEvent(
          test: "CounterTests.resets", testHashed: false, target: "CounterTests", outcome: .proven,
          proofBase: "cf01e73", assertion: assertion)))
    let folded = RunViewEmittedEvents.fold([gate, proof], into: view)
    #expect(
      folded.proofs == [
        RunView.Proof(
          gateRun: gateRun, task: task, test: "CounterTests.resets", outcome: .proven,
          proofBase: "cf01e73", assertion: assertion)
      ])
  }

  @Test("a prove.result naming no gate run shows as damage — catches a proof silently dropped")
  func proofWithoutGate() throws {
    let proof = HarnessEvent(
      eventID: "p", time: try time("2026-10-04T07:00:00Z"),
      source: HarnessEventSource(route: .check),
      payload: .proveResult(
        ProveResultEvent(
          test: "CounterTests.resets", testHashed: false, target: "CounterTests",
          outcome: .passesReverted, proofBase: nil, assertion: nil)))
    let folded = RunViewEmittedEvents.fold([proof], into: RunView(run: RunView.Run(id: "b")))
    #expect(folded.proofs.isEmpty)
    #expect(folded.damage == [RunView.Damage(source: "prove.result p", reason: "no gate run")])
  }
}

import Foundation

/// Folds the events a run emits for the view, spans, proofs, step starts and tool summaries,
/// into a view the derived spans already fill.
///
/// Step starts are placed where gate spans are derived, and tool summaries are attributed after
/// this fold, so the spans folded here get theirs too.
public enum RunViewEmittedEvents {
  public static func fold(_ events: [HarnessEvent], into view: RunView) -> RunView {
    var view = view
    view.spans = ordered(view.spans + spans(events, in: &view))
    view.proofs += proofs(events, in: &view)
    return view
  }

  /// Each `span.start` with its `span.end`. A span with no parent sits under its task's span, or
  /// the run's. One with no end stays open; in a done run it never ended, which the page shows
  /// and the footer names.
  private static func spans(_ events: [HarnessEvent], in view: inout RunView) -> [RunView.Span] {
    var ends: [String: (event: HarnessEvent, end: SpanEndEvent)] = [:]
    var starts: [(event: HarnessEvent, start: SpanStartEvent)] = []
    var startIDs = Set<String>()
    for event in events {
      switch event.payload {
      case .spanStart(let start):
        guard startIDs.insert(start.spanID).inserted else {
          view.damage.append(
            RunView.Damage(
              source: "span.start \(event.eventID)", reason: "span \(start.spanID) started twice"))
          continue
        }
        starts.append((event, start))
      case .spanEnd(let end):
        guard ends[end.spanID] == nil else {
          view.damage.append(
            RunView.Damage(
              source: "span.end \(event.eventID)", reason: "span \(end.spanID) ended twice"))
          continue
        }
        ends[end.spanID] = (event, end)
      default: continue
      }
    }
    for (spanID, end) in ends where !startIDs.contains(spanID) {
      view.damage.append(
        RunView.Damage(
          source: "span.end \(end.event.eventID)", reason: "span \(spanID) never started"))
    }
    let existing = Set(view.spans.map(\.id))
    let runSpan = existing.contains(RunViewSpans.runSpanID) ? RunViewSpans.runSpanID : nil
    return starts.map { event, start in
      let end = ends[start.spanID]
      if end == nil, view.run.state == .done {
        view.damage.append(
          RunView.Damage(
            source: "span.start \(event.eventID)",
            reason: "\(start.phase.rawValue) span \(start.spanID) never ended"))
      }
      var parent = start.parentSpan
      if let named = parent, !startIDs.contains(named) {
        view.damage.append(
          RunView.Damage(
            source: "span.start \(event.eventID)", reason: "parent span \(named) never started"))
        parent = nil
      }
      let taskSpan = start.task.map(RunViewSpans.taskSpanID).flatMap {
        existing.contains($0) ? $0 : nil
      }
      return RunView.Span(
        id: start.spanID, parent: parent ?? taskSpan ?? runSpan, phase: phase(start.phase),
        task: start.task, start: event.time, end: end?.event.time, outcome: end?.end.outcome)
    }
  }

  /// Each `prove.result` under the gate run that wrote it, and that gate's task.
  private static func proofs(_ events: [HarnessEvent], in view: inout RunView) -> [RunView.Proof] {
    var runIDOfGateEvent: [String: String] = [:]
    for event in events {
      if case .gateRun = event.payload, let runID = event.runID {
        runIDOfGateEvent[event.eventID] = runID
      }
    }
    var taskOfGateRun: [String: String] = [:]
    for gate in view.gates {
      if let task = gate.task { taskOfGateRun[gate.runID] = task }
    }
    return events.compactMap { event in
      guard case .proveResult(let proof) = event.payload else { return nil }
      guard let gateRun = event.runID ?? event.parentID.flatMap({ runIDOfGateEvent[$0] }) else {
        view.damage.append(
          RunView.Damage(source: "prove.result \(event.eventID)", reason: "no gate run"))
        return nil
      }
      return RunView.Proof(
        gateRun: gateRun, task: taskOfGateRun[gateRun], test: proof.test, outcome: proof.outcome,
        proofBase: proof.proofBase, assertion: proof.assertion)
    }
  }

  private static func phase(_ phase: SpanPhase) -> RunView.Phase {
    switch phase {
    case .specRead: .specRead
    case .discover: .discover
    case .explore: .explore
    case .plan: .plan
    case .contract: .contract
    case .worker: .worker
    case .review: .review
    case .verify: .verify
    case .fix: .fix
    case .final: .final
    case .ship: .ship
    }
  }

  /// Parents start no later than their children, so ties keep fold order: parent first.
  private static func ordered(_ spans: [RunView.Span]) -> [RunView.Span] {
    spans.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
      .map(\.element)
  }
}

import Foundation

/// The spans no event times: the run, each task, each merge and each gate with its tiers and
/// steps, derived from the ledger's events and `gate.run`. Derived ids are stable across reads,
/// so a live page merging by id replaces a span rather than adding it twice.
enum RunViewSpans {
  static let runSpanID = "run"

  static func taskSpanID(_ task: String) -> String { "task:\(task)" }

  struct Derived {
    var spans: [RunView.Span] = []
    var gates: [RunView.Gate] = []
    var damage: [RunView.Damage] = []
  }

  /// What the run's ledger events and returns say, gathered once.
  struct Join {
    /// Each gate run's task: a return's task gate or a ledger merge gate.
    var taskOfGateRun: [String: String] = [:]
    /// The merge span each ledger merge gate closes.
    var mergeSpanOfGateRun: [String: String] = [:]
    var finalGate: BuildEvent.Gate?
  }

  static func join(_ run: BuildJoin.Run?) -> Join {
    var join = Join()
    guard let run else { return join }
    for (task, taskReturn) in run.returns {
      if let gate = taskReturn.gate { join.taskOfGateRun[gate.runID] = task }
    }
    for event in run.events {
      guard case .gate(let gate) = event else { continue }
      switch gate.stage {
      case .merge(let task): join.taskOfGateRun[gate.runID] = task
      case .final: join.finalGate = gate
      }
    }
    return join
  }

  /// The run span; `nil` when nothing says when the run started.
  static func runSpan(start: Date?, state: RunView.RunState, end: Date?, join: Join)
    -> RunView.Span?
  {
    guard let start else { return nil }
    let settled: SpanOutcome? =
      switch state {
      case .done: join.finalGate.map { outcome(of: $0.verdict) }
      case .halted: .halted
      case .running: nil
      }
    return RunView.Span(
      id: runSpanID, phase: .run, start: start, end: state == .done ? end : nil, outcome: settled)
  }

  /// Each task from its move into `in-progress` to `done` or `abandoned`, to a `blocked` or
  /// `needs-replan` it didn't leave, or to the run's end,
  /// and each merge from the ledger's `merge` to the gate or undo that settles it.
  static func taskSpans(
    tasks: [LedgerTask], events: [BuildEvent], parent: String?, runEnd: Date?, join: inout Join
  ) -> [RunView.Span] {
    var spans: [RunView.Span] = []
    for task in tasks {
      let own = events.filter { $0.task == task.id }
      guard
        let startIndex = own.firstIndex(where: {
          if case .transition(let move) = $0, move.to == .inProgress { return true }
          return false
        }), case .transition(let start) = own[startIndex]
      else { continue }
      var end = runEnd
      var outcome: SpanOutcome?
      for event in own[startIndex...] {
        guard case .transition(let move) = event else { continue }
        switch move.to {
        case .done:
          (end, outcome) = (move.at, .ok)
        case .abandoned:
          (end, outcome) = (move.at, .abandoned)
        // A stop to ask ends the span, unless the task picks up again.
        case .blocked, .needsReplan:
          (end, outcome) = (move.at, .halted)
        case .inProgress, .pending:
          (end, outcome) = (runEnd, nil)
        }
        if move.to == .done || move.to == .abandoned { break }
      }
      let taskSpan = taskSpanID(task.id)
      spans.append(
        RunView.Span(
          id: taskSpan, parent: parent, phase: .task, task: task.id, start: start.at, end: end,
          outcome: outcome))
      spans += mergeSpans(of: task.id, in: own, parent: taskSpan, join: &join)
    }
    return spans
  }

  private static func mergeSpans(
    of task: String, in events: [BuildEvent], parent: String, join: inout Join
  ) -> [RunView.Span] {
    var spans: [RunView.Span] = []
    var open: RunView.Span?
    for event in events {
      switch event {
      case .merge(let merge):
        if let open { spans.append(open) }
        open = RunView.Span(
          id: "merge:\(task):\(spans.count + 1)", parent: parent, phase: .merge, task: task,
          start: merge.at)
      case .gate(let gate):
        guard var span = open else { continue }
        span.end = gate.at
        span.outcome = outcome(of: gate.verdict)
        span.gateRun = gate.runID
        join.mergeSpanOfGateRun[gate.runID] = span.id
        spans.append(span)
        open = nil
      case .undo(let undo):
        guard var span = open else { continue }
        span.end = undo.at
        span.outcome = .red
        spans.append(span)
        open = nil
      case .transition, .returnCheck: continue
      }
    }
    if let open { spans.append(open) }
    return spans
  }

  /// Each `gate.run` as a span ending at its event and starting `ms` earlier, with its steps
  /// nested under it through `parentID`, and its row for the gates table.
  static func gates(
    events: [HarnessEvent], join: Join, taskSpans: Set<String>, runSpan: String?
  ) -> Derived {
    var derived = Derived()
    var stepsByGate: [String: [GateStepEvent]] = [:]
    for event in events {
      if case .gateStep(let step) = event.payload, let parent = event.parentID {
        stepsByGate[parent, default: []].append(step)
      }
    }
    var seen = Set<String>()
    for event in events {
      guard case .gateRun(let run) = event.payload else { continue }
      guard let runID = event.runID else {
        derived.damage.append(
          RunView.Damage(source: "gate.run \(event.eventID)", reason: "no run id"))
        continue
      }
      guard seen.insert(runID).inserted else { continue }
      let task = join.taskOfGateRun[runID]
      let parent =
        join.mergeSpanOfGateRun[runID]
        ?? task.map(taskSpanID).flatMap { taskSpans.contains($0) ? $0 : nil } ?? runSpan
      let end = event.time
      let start = end.addingTimeInterval(-seconds(run.milliseconds))
      let gateSpan = RunView.Span(
        id: "gate:\(runID)", parent: parent, phase: .gate, task: task, gateRun: runID,
        start: start, end: end, outcome: outcome(of: run.verdict))
      let steps = stepsByGate[event.eventID] ?? []
      derived.spans.append(gateSpan)
      derived.spans += stepSpans(steps, of: run, gate: gateSpan)
      derived.gates.append(
        RunView.Gate(
          runID: runID, task: task, command: run.command, verdict: run.verdict,
          milliseconds: run.milliseconds, tests: run.testCounts, ruleCounts: run.ruleCounts,
          steps: steps.map {
            RunView.GateStepRow(
              tier: $0.tier, step: $0.step, startMs: $0.startMs, milliseconds: $0.milliseconds,
              verdict: $0.verdict)
          }))
    }
    return derived
  }

  /// A step with a start offset sits at it; one without starts where the step before it ended,
  /// and is approximate. Each tier spans its steps. Nothing reaches past the gate's end.
  private static func stepSpans(
    _ steps: [GateStepEvent], of run: GateRunEvent, gate: RunView.Span
  ) -> [RunView.Span] {
    guard let runID = gate.gateRun, let gateEnd = gate.end else { return [] }
    var placed: [RunView.Span] = []
    var cursor = gate.start
    for (index, step) in steps.enumerated() {
      let start = min(
        step.startMs.map { gate.start.addingTimeInterval(seconds($0)) } ?? cursor, gateEnd)
      let end = min(start.addingTimeInterval(seconds(step.milliseconds)), gateEnd)
      cursor = end
      placed.append(
        RunView.Span(
          id: "step:\(runID):\(index + 1)",
          parent: step.tier.map { "tier:\(runID):\($0.rawValue)" } ?? gate.id, phase: .step,
          task: gate.task, gateRun: runID, start: start, end: end,
          outcome: outcome(of: step.verdict), approximate: step.startMs == nil))
    }
    var tiers: [RunView.Span] = []
    for tier in steps.compactMap(\.tier).uniqued() {
      let id = "tier:\(runID):\(tier.rawValue)"
      let own = placed.filter { $0.parent == id }
      guard let start = own.map(\.start).min(), let end = own.compactMap(\.end).max() else {
        continue
      }
      let verdict =
        run.tiers.first { $0.tier == tier }?.verdict
        ?? steps.filter { $0.tier == tier }.map(\.verdict).reduce(Verdict.green) {
          $0.merged(with: $1)
        }
      tiers.append(
        RunView.Span(
          id: id, parent: gate.id, phase: .tier, task: gate.task, gateRun: runID, start: start,
          end: end, outcome: outcome(of: verdict), approximate: own.contains(where: \.approximate)
        ))
    }
    return tiers + placed
  }

  /// A brownfield run's discovery and warm-up, which time themselves in `discover.run` and
  /// `warmup.run` rather than in spans: each `discover.run` ends at its event and starts `ms`
  /// earlier. The warm-up writes an area's steps together when the area finishes, so its last
  /// step ends at the event and each earlier step ends where the next one starts; those
  /// boundaries are inferred, so each warm-up span is approximate.
  static func brownfieldSpans(events: [HarnessEvent], parent: String?) -> [RunView.Span] {
    var spans: [RunView.Span] = []
    var batch: [(event: HarnessEvent, run: WarmupRunEvent)] = []
    func flush() {
      var end = batch.last?.event.time
      var placed: [RunView.Span] = []
      for (event, run) in batch.reversed() {
        guard let stepEnd = end else { break }
        let start = stepEnd.addingTimeInterval(-seconds(run.milliseconds))
        placed.append(
          RunView.Span(
            id: "warmup:\(run.area):\(run.step.rawValue):\(event.eventID)", parent: parent,
            phase: .warmup, start: start, end: stepEnd, outcome: outcome(of: run.outcome),
            approximate: true))
        end = start
      }
      spans += placed.reversed()
      batch = []
    }
    for event in events {
      switch event.payload {
      case .discoverRun(let run):
        spans.append(
          RunView.Span(
            id: "discover:\(event.eventID)", parent: parent, phase: .discover,
            start: event.time.addingTimeInterval(-seconds(run.milliseconds)), end: event.time,
            outcome: .ok))
      case .warmupRun(let run):
        if let last = batch.last, last.run.area != run.area || last.event.time != event.time {
          flush()
        }
        batch.append((event, run))
      default:
        continue
      }
    }
    flush()
    return spans
  }

  private static func outcome(of warmup: WarmupOutcome) -> SpanOutcome {
    switch warmup {
    case .passed: .ok
    case .failed: .red
    case .dropped, .notInstalled: .abandoned
    }
  }

  static func outcome(of verdict: Verdict) -> SpanOutcome {
    switch verdict {
    case .green: .ok
    case .red, .blocked: .red
    }
  }

  private static func seconds(_ milliseconds: Int) -> TimeInterval {
    TimeInterval(milliseconds) / 1000
  }
}

extension BuildEvent {
  var at: Date {
    switch self {
    case .transition(let move): move.at
    case .merge(let merge): merge.at
    case .undo(let undo): undo.at
    case .gate(let gate): gate.at
    case .returnCheck(let check): check.at
    }
  }
}

extension Sequence where Element: Hashable {
  fileprivate func uniqued() -> [Element] {
    var seen = Set<Element>()
    return filter { seen.insert($0).inserted }
  }
}

import Foundation

/// Folds 1 build run's events, ledger and plan into a ``RunView``. Pure.
public enum RunViewBuilder {
  public static func build(_ input: RunViewInput) -> RunView {
    let events = distinct(input.events)
    let ledgerEvents = input.join?.events ?? []
    let tasks = input.ledger?.tasks ?? []
    var join = RunViewSpans.join(input.join)
    join.taskOfGateRun.merge(input.workerGateRuns) { named, _ in named }

    let times = events.map(\.time) + ledgerEvents.map(\.at)
    // A brownfield run starts at its launch, before discovery and its build run.
    let startedAt = [input.launchedAt, input.join?.record?.startedAt ?? times.min()]
      .compactMap { $0 }.min()
    let lastTime = times.max()
    let state: RunView.RunState =
      !BuildHalts.open(in: events).isEmpty ? .halted : join.finalGate == nil ? .running : .done
    let runEnd = state == .done ? lastTime : nil

    let runSpan = RunViewSpans.runSpan(start: startedAt, state: state, end: lastTime, join: join)
    let taskSpans = RunViewSpans.taskSpans(
      tasks: tasks, events: ledgerEvents, parent: runSpan?.id, runEnd: runEnd, join: &join)
    let gates = RunViewSpans.gates(
      events: events, join: join, taskSpans: Set(taskSpans.map(\.id)), runSpan: runSpan?.id)

    var damage = input.damage + gates.damage
    let usage = events.compactMap { event -> AgentUsageEvent? in
      guard case .agentUsage(let usage) = event.payload else { return nil }
      return usage
    }
    let viewTasks = tasks.map { task in
      self.task(
        task, events: ledgerEvents, returns: input.join?.returns ?? [:], usage: usage,
        brief: input.briefs[task.id].map { guarded($0, task: task.id, damage: &damage) })
    }

    var view = RunView(
      run: RunView.Run(
        id: input.buildRun, plan: input.join?.plan, preset: input.join?.record?.presetName,
        startedAt: startedAt, endedAt: runEnd, state: state,
        stallMin: input.join?.record?.preset.stallMin),
      spec: RunViewRequirements.rows(input.requirements, tasks: tasks),
      tasks: viewTasks,
      roles: roles(usage),
      spans: ordered(
        (runSpan.map { [$0] } ?? []) + taskSpans + gates.spans
          + RunViewSpans.brownfieldSpans(events: events, parent: runSpan?.id)),
      gates: gates.gates,
      halts: halts(events),
      damage: damage)
    view = RunViewEmittedEvents.fold(events, into: view)
    let windows = events.compactMap { event -> AgentToolsEvent? in
      guard case .agentTools(let tools) = event.payload else { return nil }
      return tools
    }
    let summaries = SpanToolAttribution.attribute(windows: windows, spans: view.spans)
    for index in view.spans.indices {
      if let summary = summaries[view.spans[index].id] { view.spans[index].tools = summary }
    }
    RunViewGateFailures.fill(&view, input: input, events: events)
    return view
  }

  /// An event read from 2 stores counts once.
  private static func distinct(_ events: [HarnessEvent]) -> [HarnessEvent] {
    var seen = Set<String>()
    return events.filter { seen.insert($0.eventID).inserted }
  }

  /// Parents start no later than their children, so ties keep build order: parent first.
  private static func ordered(_ spans: [RunView.Span]) -> [RunView.Span] {
    spans.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
      .map(\.element)
  }

  /// The ledger entry's own fields, less its worktree, the 1 absolute path the ledger holds.
  private static func task(
    _ task: LedgerTask, events: [BuildEvent], returns: [String: TaskReturn],
    usage: [AgentUsageEvent], brief: RunView.Brief?
  ) -> RunView.Task {
    let own = events.filter { $0.task == task.id }
    var mergedAt: Date?
    var mergeGateRun: String?
    for event in own {
      switch event {
      case .merge(let merge): mergedAt = merge.at
      case .undo: mergedAt = nil
      case .gate(let gate): mergeGateRun = gate.runID
      case .transition, .returnCheck: continue
      }
    }
    // Usage is ingested when a worker finishes, so a task not yet finished has none to sum.
    let finished = task.status != .pending && task.status != .inProgress
    return RunView.Task(
      id: task.id, status: task.status, model: task.model, deps: task.deps,
      writes: task.writeSet, gate: task.gate, covers: task.covers,
      commits: returns[task.id]?.commits ?? [], gateRun: returns[task.id]?.gate?.runID,
      mergeGateRun: mergeGateRun, createdAt: own.first?.at, mergedAt: mergedAt, brief: brief,
      tokens: finished ? tokens(usage.filter { $0.task == task.id }) : nil)
  }

  private static func tokens(_ usage: [AgentUsageEvent]) -> RunView.Tokens {
    var tokens = RunView.Tokens()
    for message in usage {
      tokens.input += message.inputTokens
      tokens.output += message.outputTokens
      tokens.cacheRead += message.cacheReadTokens
      tokens.cacheWrite += message.cacheCreationTokens
    }
    return tokens
  }

  private static func roles(_ usage: [AgentUsageEvent]) -> [RunView.Role] {
    AgentRole.allCases.compactMap { role in
      let own = usage.filter { $0.role == role }
      return own.isEmpty ? nil : RunView.Role(role: role, tokens: tokens(own))
    }
  }

  private static func halts(_ events: [HarnessEvent]) -> [RunView.Halt] {
    var resumes: [String: BuildResumeEvent] = [:]
    for event in events {
      if case .buildResume(let resume) = event.payload, let parent = event.parentID {
        resumes[parent] = resume
      }
    }
    return events.compactMap { event in
      guard case .buildHalt(let halt) = event.payload else { return nil }
      let resume = resumes[event.eventID]
      return RunView.Halt(
        task: halt.task, reason: halt.reason, at: event.time, answer: resume?.answer,
        waitMs: resume?.waitMilliseconds)
    }
  }

  /// Each string cut to ``RunView/maxBriefBytes``; one the payload guard rejects drops out as a
  /// damage row naming the task and field, so 1 bad line can't fail the report.
  private static func guarded(_ brief: RunView.Brief, task: String, damage: inout [RunView.Damage])
    -> RunView.Brief
  {
    func keep(_ text: String, _ field: String) -> String? {
      let cut = RunViewText.cut(text, toBytes: RunView.maxBriefBytes)
      guard let reason = EventPayloadGuard.rejection(inJSON: cut) else { return cut }
      damage.append(
        RunView.Damage(source: "brief of \(task)", reason: "\(field): \(reason.rawValue)"))
      return nil
    }
    func keep(_ texts: [String], _ field: String) -> [String] {
      texts.enumerated().compactMap { keep($0.element, "\(field)[\($0.offset)]") }
    }
    return RunView.Brief(
      title: keep(brief.title, "title") ?? "", why: keep(brief.why, "why") ?? "",
      designRef: brief.designRef.flatMap { keep($0, "designRef") },
      scope: keep(brief.scope, "scope"), acceptance: keep(brief.acceptance, "acceptance"),
      outOfScope: keep(brief.outOfScope, "outOfScope"))
  }
}

import Foundation

/// Build halts: wait per reason, idle slot-minutes and retries per task.
public struct HaltsSection: EventSummarySection {
  /// The build runs to replay; `nil` when the build state wasn't read.
  public let builds: BuildJoin?

  public init(builds: BuildJoin? = nil) {
    self.builds = builds
  }

  public var id: EventSummarySectionID { .halts }

  /// The task group of a halt of the whole run.
  static let wholeRun = "whole run"

  public func summarize(_ input: EventSummaryInput) -> EventSummarySectionReport? {
    let wanted = input.query.buildRunID
    let events = input.events.map(\.event).filter { event in
      switch event.payload {
      case .buildHalt(let halt): wanted.map { halt.buildRun == $0 } ?? true
      case .buildResume(let resume): wanted.map { resume.buildRun == $0 } ?? true
      case .judgeDecision, .judgeCall, .gateRun, .gateStep: false
      case .hookDecision, .testResult, .cacheLookup, .agentUsage: false
      case .discoverRun, .warmupRun, .buildReturnChecked: false
      case .spanStart, .spanEnd, .proveResult, .agentTools, .qaCheck: false
      }
    }
    let runs = (builds?.runs ?? []).filter { run in
      if let wanted, run.runID != wanted { return false }
      guard let since = input.query.since else { return true }
      return run.events.contains { Self.time(of: $0) >= since }
    }
    guard !events.isEmpty || !runs.isEmpty else { return nil }

    var lines: [String] = []
    var metrics: [EventSummaryMetric] = []
    waits(events, lines: &lines, metrics: &metrics)
    open(events, now: input.now, lines: &lines, metrics: &metrics)
    if let builds, runs.isEmpty {
      lines.append("idle slots and retries: no build runs under \(builds.source) (n=0)")
    } else if builds != nil {
      replays(runs, now: input.now, lines: &lines, metrics: &metrics)
    } else {
      lines.append("idle slots and retries: the build state wasn't read")
    }
    return EventSummarySectionReport(id: id, state: .reported, lines: lines, metrics: metrics)
  }

  private func waits(
    _ events: [HarnessEvent], lines: inout [String], metrics: inout [EventSummaryMetric]
  ) {
    var reasons: [String: BuildHaltReason] = [:]
    for event in events {
      if case .buildHalt(let halt) = event.payload { reasons[event.eventID] = halt.reason }
    }
    var answered: [BuildHaltReason: [BuildResumeEvent]] = [:]
    var resumes = 0
    var unmatched = 0
    for event in events {
      guard case .buildResume(let resume) = event.payload else { continue }
      resumes += 1
      guard let parent = event.parentID, let reason = reasons[parent] else {
        unmatched += 1
        continue
      }
      answered[reason, default: []].append(resume)
    }
    guard resumes > 0 else {
      lines.append("waits per reason: no halt answered yet (n=0)")
      return
    }
    lines.append("waits per reason, over answered halts:")
    for reason in BuildHaltReason.allCases {
      guard let ofReason = answered[reason],
        let stats = TimingStats(milliseconds: ofReason.map(\.waitMilliseconds))
      else { continue }
      let group = [reason.rawValue]
      metrics += [
        EventSummaryMetric(
          name: "wait-p50", group: group, value: Double(stats.p50), unit: .milliseconds,
          n: stats.n),
        EventSummaryMetric(
          name: "wait-p95", group: group, value: Double(stats.p95), unit: .milliseconds,
          n: stats.n),
        EventSummaryMetric(
          name: "wait-sd", group: group, value: stats.standardDeviation, unit: .milliseconds,
          n: stats.n),
      ]
      var answers: [String] = []
      for answer in BuildResumeAnswer.allCases {
        let count = ofReason.count { $0.answer == answer }
        guard count > 0 else { continue }
        metrics.append(
          EventSummaryMetric(
            name: "answers", group: [reason.rawValue, answer.rawValue], value: Double(count),
            unit: .count, n: ofReason.count))
        answers.append("\(answer.rawValue) \(count)")
      }
      lines.append(
        "  \(reason.rawValue): \(stats.rendered); answers: \(answers.joined(separator: ", "))")
    }
    if unmatched > 0 {
      metrics.append(
        EventSummaryMetric(
          name: "unmatched-resumes", group: [], value: Double(unmatched), unit: .count,
          n: resumes))
      lines.append(
        "  \(unmatched) of \(resumes) resumes answer a halt outside the events read, so their "
          + "reason is unknown")
    }
  }

  /// Halts no resume answered. Each stays listed with its age: a build left halted overnight
  /// is the wait that matters most, and it has no resume to time it.
  private func open(
    _ events: [HarnessEvent], now: Date, lines: inout [String],
    metrics: inout [EventSummaryMetric]
  ) {
    let halts = events.count { if case .buildHalt = $0.payload { true } else { false } }
    guard halts > 0 else { return }
    let open = BuildHalts.open(in: events)
    metrics.append(
      EventSummaryMetric(
        name: "open-halts", group: [], value: Double(open.count), unit: .count, n: halts))
    lines.append("open halts: \(open.count) of \(halts) halts (n=\(halts))")
    for event in open {
      guard case .buildHalt(let halt) = event.payload else { continue }
      let age = BuildHalts.waitMilliseconds(from: event.time, to: now)
      let task = halt.task.map { "task \($0)" } ?? Self.wholeRun
      metrics.append(
        EventSummaryMetric(
          name: "open-age",
          group: [halt.reason.rawValue, halt.buildRun, halt.task ?? Self.wholeRun],
          value: Double(age), unit: .milliseconds, n: 1))
      lines.append(
        "  open: \(halt.reason.rawValue), build run \(halt.buildRun), \(task), waiting "
          + "\(Self.duration(age)) since \(event.time.formatted(HarnessEventJSON.timeFormat))")
    }
  }

  private func replays(
    _ runs: [BuildJoin.Run], now: Date, lines: inout [String],
    metrics: inout [EventSummaryMetric]
  ) {
    var replayed: [(run: BuildJoin.Run, replay: SlotReplay)] = []
    var unreplayed: [BuildJoin.Run] = []
    for run in runs {
      guard let record = run.record else {
        unreplayed.append(run)
        continue
      }
      replayed.append(
        (run, SlotReplay(events: run.events, maxParallel: record.preset.maxParallel, now: now)))
    }
    let idle = replayed.map(\.replay.idleSlotMilliseconds).reduce(0, +)
    if !replayed.isEmpty {
      metrics.append(
        EventSummaryMetric(
          name: "idle-slot-ms", group: [], value: Double(idle), unit: .milliseconds,
          n: replayed.count))
    }
    lines.append(
      "idle slot-minutes: \(Self.minutes(idle)) over \(replayed.count) replayed build runs "
        + "(n=\(replayed.count))")
    for (run, replay) in replayed {
      metrics.append(
        EventSummaryMetric(
          name: "idle-slot-ms", group: [run.runID], value: Double(replay.idleSlotMilliseconds),
          unit: .milliseconds, n: replay.transitions))
      lines.append(
        "  \(run.runID): \(Self.minutes(replay.idleSlotMilliseconds)) idle slot-minutes over "
          + "\(Self.minutes(replay.spanMilliseconds)) minutes on \(replay.maxParallel) slots "
          + "(n=\(replay.transitions) transitions)"
          + (replay.openAtEnd ? "; a task is still in progress, so replayed to now" : ""))
    }
    if !unreplayed.isEmpty {
      metrics.append(
        EventSummaryMetric(
          name: "unreplayed-runs", group: [], value: Double(unreplayed.count), unit: .count,
          n: runs.count))
      for run in unreplayed {
        lines.append("  \(run.runID): not replayed, no run.json to give its maxParallel")
      }
    }
    let started = replayed.map(\.replay.starts.count).reduce(0, +)
    let retried = replayed.flatMap { entry in
      entry.replay.retries.sorted { $0.key < $1.key }.map {
        (
          runID: entry.run.runID, task: $0.key, retries: $0.value,
          starts: entry.replay.starts[$0.key, default: 0]
        )
      }
    }
    metrics.append(
      EventSummaryMetric(
        name: "retries", group: [], value: Double(retried.map(\.retries).reduce(0, +)),
        unit: .count, n: started))
    guard !retried.isEmpty else {
      lines.append("retries per task: none (n=\(started) tasks started)")
      return
    }
    lines.append("retries per task (n=\(started) tasks started):")
    for (runID, task, retries, starts) in retried {
      metrics.append(
        EventSummaryMetric(
          name: "retries", group: [runID, task], value: Double(retries), unit: .count,
          n: starts))
      lines.append("  \(runID) \(task): \(retries) (n=\(starts) starts)")
    }
  }

  static func time(of event: BuildEvent) -> Date {
    switch event {
    case .transition(let transition): transition.at
    case .merge(let merge): merge.at
    case .undo(let undo): undo.at
    case .gate(let gate): gate.at
    case .returnCheck(let check): check.at
    }
  }

  /// `1h 5m`, or `5m 3s` under an hour.
  static func duration(_ milliseconds: Int) -> String {
    let seconds = milliseconds / 1000
    let hours = seconds / 3600
    let minutes = seconds % 3600 / 60
    return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m \(seconds % 60)s"
  }

  static func minutes(_ milliseconds: Int) -> String {
    String(format: "%.1f", Double(milliseconds) / 60_000)
  }
}

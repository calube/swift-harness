import Foundation

extension RunView {
  /// A failure reason's cap in words, so it reads at a glance.
  public static let maxReasonWords = 15
  /// A failure reason's cap in UTF-8 bytes.
  public static let maxReasonBytes = 120
}

/// The one-line failure reason each span and task that isn't ok carries, in plain words. The
/// popover's "Why it failed" section stays the longer view.
public enum RunViewFailureReasons {
  public static let noReason = "No reason recorded."
  public static let neverEnded = "Never ended; no end event recorded."
  static let withheld = "Reason withheld: it fails the payload guard."

  /// `text` on 1 line, with machine paths taken out, cut to ``RunView/maxReasonWords`` words and
  /// ``RunView/maxReasonBytes`` bytes, ending in `…` when cut.
  public static func capped(_ text: String, roots: [String] = []) -> String {
    let (line, _) = RunViewGateFailures.Scrub.message(
      text, roots: RunViewGateFailures.Scrub.roots(roots))
    let words = line.split(separator: " ")
    var out =
      words.count > RunView.maxReasonWords
      ? words.prefix(RunView.maxReasonWords).joined(separator: " ") + "…" : line
    if out.utf8.count > RunView.maxReasonBytes {
      out = RunViewText.cut(out, toBytes: RunView.maxReasonBytes - "…".utf8.count) + "…"
    }
    return EventPayloadGuard.rejection(inJSON: out) == nil ? out : withheld
  }

  /// A warm-up step's reason, and whether the baseline recorded its failure.
  public static func warmup(_ run: WarmupRunEvent, baseline: BaselineStepResult?) -> (
    reason: String?, baseline: Bool
  ) {
    switch run.outcome {
    case .passed: return (nil, false)
    case .dropped: return ("Step dropped before it ran.", false)
    case .notInstalled: return ("The tool this step needs isn't installed.", false)
    case .failed: break
    }
    switch (run.step, baseline) {
    case (.generate, _):
      return ("Project generation failed at the base commit.", false)
    case (.install, _):
      return ("Dependency install failed.", false)
    case (.build, .failed?), (.build, .failedTests?):
      return ("Base commit doesn't build; failure recorded as baseline.", true)
    case (.build, .passed?):
      return ("Build failed here, but the baseline records a pass.", false)
    case (.build, nil):
      return ("Base commit doesn't build; no baseline record found.", false)
    case (.test, .failedTests(let tests)?):
      return ("Base commit's tests already fail; \(tests.count) recorded as baseline.", true)
    case (.test, .failed?):
      return (
        "Base commit's tests fail, no test names read; whole step recorded as baseline.", true
      )
    case (.test, .passed?):
      return ("Tests failed here, but the baseline records a pass.", false)
    case (.test, nil):
      return ("Base commit's tests already fail; no baseline record found.", false)
    }
  }

  /// A gate run's reason: its first gating rule and what it counts; `nil` for a GREEN run.
  public static func gate(_ gate: RunView.Gate) -> String? {
    guard gate.verdict != .green else { return nil }
    let failure = gate.failure
    if let finding = failure?.findings.first {
      guard finding.rule.hasSuffix(".test-failed") else {
        return "\(finding.rule): \(finding.message)"
      }
      let listed = failure.map { $0.failedTests.count + $0.moreFailedTests } ?? 0
      let count =
        [gate.tests?.failed ?? 0, listed, gate.ruleCounts[finding.rule] ?? 0]
        .first { $0 > 0 } ?? 1
      let branch =
        switch failure?.stage {
        case .merge?, .final?: "the merged branch"
        case .task?, .worker?: "the task branch"
        case nil: "its branch"
        }
      return "\(finding.rule): \(count) \(count == 1 ? "test fails" : "tests fail") on \(branch)."
    }
    if let failure, !failure.failedTests.isEmpty {
      let count = failure.failedTests.count + failure.moreFailedTests
      return
        "\(count) \(count == 1 ? "test" : "tests") failed; its report isn't in a live checkout."
    }
    if let tier = failure?.tiers.first {
      return "Tier \(tier.rawValue) failed; no gating finding was read."
    }
    if let rule = gate.ruleCounts.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }).first {
      return "\(rule.key): \(rule.value) \(rule.value == 1 ? "finding" : "findings")."
    }
    return gate.verdict == .blocked ? "Gate blocked before it reached a verdict." : noReason
  }

  public static func halt(_ reason: BuildHaltReason) -> String {
    switch reason {
    case .question: "Halted: waiting on an answer to a question."
    case .stall: "Halted: no agent moved before the stall watch fired."
    case .gateRed: "Halted: a gate stayed RED."
    case .mergeConflict: "Halted: merge conflict."
    case .amend: "Halted: design conflict; the design went back for an amend."
    case .budget: "Halted: the time budget ran out."
    case .permission: "Halted: a tool waits on a permission no one granted."
    }
  }

  /// A stopped task's reason, from its block; `nil` for a task that didn't stop.
  public static func task(_ task: RunView.Task, gates: [String: RunView.Gate]) -> String? {
    switch task.status {
    case .abandoned: return "Task abandoned before it merged."
    case .blocked, .needsReplan: break
    case .pending, .inProgress, .done: return nil
    }
    guard let block = task.blocked else { return noReason }
    switch block.cause {
    case .returnRejected?:
      guard let rejection = block.rejection else { return "Return rejected." }
      let what = rejection.findings.first?.message ?? rejection.rules.first?.rawValue
      let lead =
        rejection.verdict == .blocked ? "check-return couldn't judge the return" : "Return rejected"
      return what.map { "\(lead): \($0)" } ?? "\(lead)."
    case .gateRed?:
      return block.gateRun.flatMap { gates[$0] }.flatMap(gate) ?? "Its last gate run was RED."
    case .returnNotStored?:
      return "No return came back from the worker."
    case .halt?, nil:
      return block.halt.map(halt) ?? noReason
    }
  }

  /// Fills every span's and task's reason, each capped and scrubbed. A warm-up span's reason
  /// is set where the span is built; every other span not ok gets 1 here.
  public static func fill(_ view: inout RunView, input: RunViewInput) {
    let gates = Dictionary(view.gates.map { ($0.runID, $0) }) { first, _ in first }
    let finalGate = input.join?.events.reversed().lazy.compactMap { event -> String? in
      guard case .gate(let gate) = event, case .final = gate.stage else { return nil }
      return gate.runID
    }.first
    for index in view.tasks.indices {
      view.tasks[index].failureReason = task(view.tasks[index], gates: gates)
    }
    let tasks = Dictionary(view.tasks.map { ($0.id, $0) }) { first, _ in first }
    for index in view.spans.indices where view.spans[index].failureReason == nil {
      let span = view.spans[index]
      if let excused = excused(span, gates: gates) {
        view.spans[index].failureReason = excused.reason
        view.spans[index].baseline = excused.baseline
        continue
      }
      view.spans[index].failureReason = self.span(
        span, in: view, gates: gates, tasks: tasks, finalGate: finalGate)
    }
    let roots = input.checkoutRoots
    for index in view.spans.indices {
      view.spans[index].failureReason = view.spans[index].failureReason.map {
        capped($0, roots: roots)
      }
    }
    for index in view.tasks.indices {
      view.tasks[index].failureReason = view.tasks[index].failureReason.map {
        capped($0, roots: roots)
      }
    }
  }

  /// A red step or tier of a GREEN gate run: its failures didn't gate, and when the run's
  /// baseline absorbed failures, they also fail at the base commit.
  private static func excused(_ span: RunView.Span, gates: [String: RunView.Gate]) -> (
    reason: String, baseline: Bool
  )? {
    guard span.phase == .step || span.phase == .tier, span.outcome == .red,
      let gate = span.gateRun.flatMap({ gates[$0] }), gate.verdict == .green
    else { return nil }
    guard gate.ruleCounts[BrownfieldRuleID.baselineSummary.rawValue] != nil else {
      return ("Step failed, but its gate passed.", false)
    }
    return ("Fails at the base commit too; the baseline excused it.", true)
  }

  private static func span(
    _ span: RunView.Span, in view: RunView, gates: [String: RunView.Gate],
    tasks: [String: RunView.Task], finalGate: String?
  ) -> String? {
    guard span.end != nil else { return view.run.state == .done ? neverEnded : nil }
    guard let outcome = span.outcome, outcome != .ok else { return nil }
    let task = span.task.flatMap { tasks[$0] }
    let newestHalt = view.halts.filter { halt in
      halt.task == span.task && span.end.map { halt.at <= $0 } ?? true
    }.max { $0.at < $1.at }
    if span.phase == .task {
      if let reason = task?.failureReason { return reason }
      if outcome == .abandoned { return "Task abandoned before it merged." }
    }
    if span.phase == .run {
      if outcome == .halted { return newestHalt.map { halt($0.reason) } ?? noReason }
      return finalGate.flatMap { gates[$0] }.flatMap(gate) ?? noReason
    }
    if let runID = span.gateRun ?? span.causeGateRun, let gate = gates[runID],
      let reason = self.gate(gate)
    {
      return reason
    }
    switch outcome {
    case .red where span.phase == .merge && span.gateRun == nil:
      return "Merge undone before its gate passed."
    case .halted:
      return newestHalt.map { halt($0.reason) } ?? "Halted; no halt reason recorded."
    case .abandoned:
      return "Abandoned before it finished."
    case .red, .ok:
      return noReason
    }
  }
}

/// Which baseline record each failed warm-up step wrote, from the warm-up's times files and the
/// baseline files of the clone. A `warmup.run` names its commit, not the base tree its files are
/// named by, so an area's steps match the 1 times file whose record of the area holds the same
/// step outcomes and, where 2 or more do, the same test time.
public enum RunViewWarmupBaselines {
  public static func match(
    events: [HarnessEvent], times: [WarmupTimesFile], baselines: [String: BaselineFile]
  ) -> [String: BaselineStepResult] {
    var batches: [[(id: String, run: WarmupRunEvent)]] = []
    var last: (area: String, time: Date)?
    for event in events {
      guard case .warmupRun(let run) = event.payload else { continue }
      if let last, last.area == run.area, last.time == event.time {
        batches[batches.count - 1].append((event.eventID, run))
      } else {
        batches.append([(event.eventID, run)])
      }
      last = (run.area, event.time)
    }
    var matched: [String: BaselineStepResult] = [:]
    for batch in batches {
      guard let area = batch.first?.run.area,
        let tree = tree(of: batch, area: area, times: times),
        let file = baselines[tree]
      else { continue }
      for (id, run) in batch {
        let step: AreaStep
        switch run.step {
        case .build: step = .build
        case .test: step = .test
        case .generate, .install: continue
        }
        // The config may have changed the command since; records that disagree match none.
        let results = Set(
          file.records.filter {
            $0.key.area == area && $0.key.step == step && $0.key.selection.isEmpty
          }.map(\.result))
        if results.count == 1, let result = results.first { matched[id] = result }
      }
    }
    return matched
  }

  private static func tree(
    of batch: [(id: String, run: WarmupRunEvent)], area: String, times: [WarmupTimesFile]
  ) -> String? {
    let fitting = times.filter { file in
      guard let record = file.areas[area] else { return false }
      return batch.allSatisfy { record.steps[$0.run.step] == $0.run.outcome }
    }
    if fitting.count == 1 { return fitting.first?.tree }
    let test = batch.first { $0.run.step == .test }?.run.milliseconds
    let timed = fitting.filter { test != nil && $0.areas[area]?.testMilliseconds == test }
    return timed.count == 1 ? timed.first?.tree : nil
  }
}

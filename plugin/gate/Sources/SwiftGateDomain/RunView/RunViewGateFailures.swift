import Foundation

/// Fills what a RED gate, the stage it turned red and the halt it caused say about the failure:
/// each non-GREEN gate's ``RunView/GateFailure``, each red stage's ``RunView/Span/causeGateRun``
/// and each `gate-red` halt's ``RunView/Halt/gateRun``.
enum RunViewGateFailures {
  /// Where a gate run sat in the build, from the run's join.
  struct Stages {
    var final: String?
    var merge: Set<String> = []
    var task: Set<String> = []
    var worker: Set<String> = []

    init(
      _ run: BuildJoin.Run?, workerGateRuns: [String: String], unattributed: Set<String> = []
    ) {
      worker = Set(workerGateRuns.keys).union(unattributed)
      guard let run else { return }
      task = Set(run.returns.values.compactMap { $0.gate?.runID })
      for event in run.events {
        guard case .gate(let gate) = event else { continue }
        switch gate.stage {
        case .merge: merge.insert(gate.runID)
        case .final: final = gate.runID
        }
      }
    }

    func stage(of runID: String) -> RunView.GateStage? {
      if runID == final { return .final }
      if merge.contains(runID) { return .merge }
      if task.contains(runID) { return .task }
      if worker.contains(runID) { return .worker }
      return nil
    }
  }

  static func fill(_ view: inout RunView, input: RunViewInput, events: [HarnessEvent]) {
    let stages = Stages(
      input.join, workerGateRuns: input.workerGateRuns, unattributed: input.unattributedGateRuns)
    let roots = Scrub.roots(input.checkoutRoots)
    var runEvents: [String: (event: HarnessEvent, run: GateRunEvent)] = [:]
    var failedTests: [String: [TestResultEvent]] = [:]
    for event in events {
      guard let runID = event.runID else { continue }
      switch event.payload {
      case .gateRun(let run): runEvents[runID] = runEvents[runID] ?? (event, run)
      case .testResult(let result) where result.outcome == .failed:
        failedTests[runID, default: []].append(result)
      default: continue
      }
    }
    for index in view.gates.indices where view.gates[index].verdict != .green {
      let runID = view.gates[index].runID
      let report = input.gateReports[runID]
      view.gates[index].failure = failure(
        runID: runID, gateRun: runEvents[runID], report: report,
        tests: failedTests[runID] ?? [], proofs: view.proofs.filter { $0.gateRun == runID },
        stage: stages.stage(of: runID), roots: roots)
    }
    causes(&view)
    haltGates(&view, table: input.validation)
    blocks(
      &view, returns: Set(input.join?.returns.keys.map { $0 } ?? []),
      rejections: rejections(events))
  }

  /// Each task's newest `build.return-checked` that wasn't GREEN, unless a later check of it was.
  private static func rejections(_ events: [HarnessEvent]) -> [String: RunView.ReturnRejection] {
    var newest: [String: (time: Date, checked: BuildReturnCheckedEvent)] = [:]
    for event in events {
      guard case .buildReturnChecked(let checked) = event.payload else { continue }
      if let seen = newest[checked.task], seen.time > event.time { continue }
      newest[checked.task] = (event.time, checked)
    }
    return newest.compactMapValues { entry in
      let checked = entry.checked
      guard checked.verdict != .green else { return nil }
      return RunView.ReturnRejection(
        at: entry.time, verdict: checked.verdict, fix: checked.fix, rules: checked.rules,
        findings: checked.findings, moreFindings: checked.moreFindings, message: checked.message)
    }
  }

  /// Each task that ended `blocked` or `needs-replan` says why, from what its record holds:
  /// `build check-return` rejecting its return, its newest gate run RED, no return of it stored,
  /// or a halt of it. Its task span, which ends there, names a RED gate run as its cause.
  private static func blocks(
    _ view: inout RunView, returns: Set<String>, rejections: [String: RunView.ReturnRejection]
  ) {
    let stopped: Set<TaskStatus> = [.blocked, .needsReplan]
    for index in view.tasks.indices where stopped.contains(view.tasks[index].status) {
      let task = view.tasks[index].id
      let spanIndex = view.spans.firstIndex { $0.phase == .task && $0.task == task }
      guard let spanIndex, view.spans[spanIndex].outcome == .halted,
        let at = view.spans[spanIndex].end
      else { continue }
      let gate = view.spans.filter { $0.phase == .gate && $0.task == task && $0.end != nil }
        .max { ($0.end ?? $0.start) < ($1.end ?? $1.start) }
      let halt = view.halts.filter { $0.task == task }.max { $0.at < $1.at }
      let rejection = rejections[task]
      // A rejected return comes first: its rules say what was wrong even when the gate it
      // claimed was RED.
      let cause: RunView.BlockCause? =
        rejection != nil
        ? .returnRejected
        : gate?.outcome == .red
          ? .gateRed : !returns.contains(task) ? .returnNotStored : halt == nil ? nil : .halt
      view.tasks[index].blocked = RunView.TaskBlock(
        at: at, cause: cause, halt: halt?.reason, gateRun: gate?.gateRun, rejection: rejection)
      if cause == .gateRed { view.spans[spanIndex].causeGateRun = gate?.gateRun }
    }
  }

  private static func failure(
    runID: String, gateRun: (event: HarnessEvent, run: GateRunEvent)?,
    report: RunViewGateReport?, tests: [TestResultEvent], proofs: [RunView.Proof],
    stage: RunView.GateStage?, roots: [String]
  ) -> RunView.GateFailure {
    let tiers =
      report.map { $0.report.tiers.filter { $0.verdict != .green }.map(\.tier) }
      ?? gateRun?.run.tiers.filter { $0.verdict != .green }.map(\.tier) ?? []
    let gating = report?.report.findings.filter(\.severity.failsGate) ?? []
    let findings = gating.prefix(RunView.maxFailureFindings).map { finding in
      let (message, truncated) = Scrub.message(finding.message, roots: roots)
      return RunView.FailureFinding(
        rule: finding.ruleID, severity: finding.severity,
        file: Scrub.file(finding.file, roots: roots), line: finding.line, message: message,
        truncated: truncated)
    }

    var failed: [RunView.FailedTest] = []
    var seen = Set<String>()
    for result in tests where seen.insert(result.test).inserted {
      let located = gating.first { finding in
        finding.ruleID.hasSuffix(".test-failed") && names(finding.message, result.test)
      }
      failed.append(
        RunView.FailedTest(
          test: result.test, tier: result.tier,
          file: located.flatMap { finding in
            Scrub.file(finding.file, roots: roots)
          }, line: located?.line))
    }
    for proof in proofs where proof.outcome != .proven && proof.outcome != .skipped {
      failed.append(
        RunView.FailedTest(
          test: proof.test, proof: proof.outcome,
          file: proof.assertion.flatMap { Scrub.file($0.file, roots: roots) },
          line: proof.assertion?.line))
    }

    return RunView.GateFailure(
      checkTier: gateRun?.event.source.tier, stage: stage, tiers: tiers,
      findings: Array(findings),
      moreFindings: max(0, gating.count - RunView.maxFailureFindings),
      failedTests: Array(failed.prefix(RunView.maxFailedTests)),
      moreFailedTests: max(0, failed.count - RunView.maxFailedTests),
      report: report.map(\.location), command: "swiftgate events list --run \(runID)")
  }

  /// Whether a test failure finding's message, which starts `<suite>/<name>(): …`, is about
  /// `test`, which `test.result` spells `<target>.<suite>/<name>`.
  static func names(_ message: String, _ test: String) -> Bool {
    guard let colon = message.range(of: ": ") else { return false }
    var id = String(message[..<colon.lowerBound])
    if id.hasSuffix("()") { id.removeLast(2) }
    guard !id.isEmpty, test.hasSuffix(id) else { return false }
    let before = test.dropLast(id.count).last
    return before == nil || before == "." || before == "/"
  }

  /// A red worker, fix, verify or review stage takes the newest RED gate run of its task that
  /// ended inside it.
  private static func causes(_ view: inout RunView) {
    let stages: Set<RunView.Phase> = [.worker, .fix, .verify, .review]
    let redGates = view.spans.filter { $0.phase == .gate && $0.outcome == .red }
    for index in view.spans.indices {
      let span = view.spans[index]
      guard stages.contains(span.phase), span.outcome == .red || span.outcome == .halted,
        let task = span.task
      else { continue }
      let inside = redGates.filter { gate in
        guard gate.task == task, let end = gate.end else { return false }
        return end >= span.start && span.end.map { end <= $0 } ?? true
      }
      view.spans[index].causeGateRun =
        inside.max { ($0.end ?? $0.start) < ($1.end ?? $1.start) }?
        .gateRun
    }
  }

  /// A `gate-red` halt takes the newest RED run of its task that ended by the halt: a gate run,
  /// or a `qa run` past the merge base with a red row that runs after the task, by the row or
  /// the plan's table, since red flows halt a merge too. A halt of the whole run takes the newest
  /// of any task.
  private static func haltGates(_ view: inout RunView, table: ValidationTable?) {
    var red: [(task: String?, end: Date, run: String)] = view.spans.compactMap { span in
      guard span.phase == .gate, span.outcome == .red, let end = span.end,
        let run = span.gateRun
      else { return nil }
      return (span.task, end, run)
    }
    for row in view.validation?.rows ?? [] {
      var tasks = row.runsAfter
      for listed in table?.rows ?? [] where listed.requirement == row.requirement {
        tasks += listed.runsAfter.filter { !tasks.contains($0) }
      }
      for attempt in row.history where attempt.result == .red && attempt.stage != .atBase {
        for task in tasks { red.append((task, attempt.at, attempt.qaRun)) }
      }
    }
    for index in view.halts.indices where view.halts[index].reason == .gateRed {
      let halt = view.halts[index]
      let before = red.filter { candidate in
        (halt.task == nil || candidate.task == halt.task) && candidate.end <= halt.at
      }
      view.halts[index].gateRun = before.max { ($0.end, $0.run) < ($1.end, $1.run) }?.run
    }
  }

  /// Keeps machine paths and multi-line text out of a finding before it enters the view.
  enum Scrub {
    /// Each root and its `/private`-less spelling, longest first, each ending in `/`.
    static func roots(_ roots: [String]) -> [String] {
      var all = Set<String>()
      for root in roots where root.hasPrefix("/") {
        let slashed = root.hasSuffix("/") ? root : root + "/"
        all.insert(slashed)
        if slashed.hasPrefix("/private/") {
          all.insert(String(slashed.dropFirst("/private".count)))
        }
      }
      return all.sorted { ($0.count, $0) > ($1.count, $1) }
    }

    /// `file` repo-relative, or `nil` for the whole repository or a path outside every root.
    static func file(_ file: String, roots: [String]) -> String? {
      guard file != "." else { return nil }
      var relative = file
      if relative.hasPrefix("/"), let root = roots.first(where: { relative.hasPrefix($0) }) {
        relative = String(relative.dropFirst(root.count))
      }
      guard EventPayloadGuard.rejection(inJSON: relative) == nil, !relative.isEmpty else {
        return nil
      }
      return relative
    }

    /// `message` on 1 line, each path under a root made relative and every other absolute or
    /// home path replaced by `<path>`, cut to ``RunView/maxFailureMessageBytes``; and whether
    /// it was cut.
    static func message(_ message: String, roots: [String]) -> (String, Bool) {
      var text = message
      for root in roots {
        text = text.replacingOccurrences(of: "file://" + root, with: "")
        text = text.replacingOccurrences(of: root, with: "")
      }
      text = paths(in: text)
      let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
      let cut = RunViewText.cut(line, toBytes: RunView.maxFailureMessageBytes)
      if let reason = EventPayloadGuard.rejection(inJSON: cut) {
        return ("message withheld: it fails the payload guard (\(reason.rawValue))", true)
      }
      return (cut, cut != line)
    }

    /// Characters a path in prose can follow.
    private static let openers: Set<Character> = ["\"", "'", "`", "(", "[", "{", "<", "=", ","]
    /// Characters that end a path in prose.
    private static let closers: Set<Character> = ["\"", "'", "`", ")", "]", "}", ">", ",", ";"]

    /// `text` with each absolute path, home path or `file://` URL replaced by `<path>`.
    private static func paths(in text: String) -> String {
      var out = ""
      var index = text.startIndex
      while index < text.endIndex {
        guard startsPath(text, at: index) else {
          out.append(text[index])
          index = text.index(after: index)
          continue
        }
        while index < text.endIndex, !text[index].isWhitespace, !closers.contains(text[index]) {
          index = text.index(after: index)
        }
        out += "<path>"
      }
      return out
    }

    /// Whether a path starts at `index`: `file://`, `~/` or `/` and a path character, at the
    /// start of the text or after a space or an opener.
    private static func startsPath(_ text: String, at index: String.Index) -> Bool {
      if index > text.startIndex {
        let previous = text[text.index(before: index)]
        guard previous.isWhitespace || openers.contains(previous) else { return false }
      }
      let rest = text[index...]
      if rest.hasPrefix("file://") || rest.hasPrefix("~/") { return true }
      guard rest.first == "/", let next = rest.dropFirst().first else { return false }
      return !next.isWhitespace && !closers.contains(next)
    }
  }
}

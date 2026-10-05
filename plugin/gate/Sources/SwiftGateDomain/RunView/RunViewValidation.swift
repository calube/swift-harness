import Foundation

/// The run viewer's Validation tab: the newest result of each validation row a `qa run` checked
/// during the build run, with the counts its summary strip shows.
public struct RunViewValidation: Sendable, Equatable, Encodable {
  /// How many lines of a red check's saved output the view keeps: the last ones.
  public static let maxOutputLines = 12

  public struct Counts: Sendable, Equatable, Encodable {
    public var pass: Int
    public var red: Int
    public var unverified: Int
    public var waiting: Int
    public var abandoned: Int

    public init(
      pass: Int = 0, red: Int = 0, unverified: Int = 0, waiting: Int = 0, abandoned: Int = 0
    ) {
      self.pass = pass
      self.red = red
      self.unverified = unverified
      self.waiting = waiting
      self.abandoned = abandoned
    }
  }

  /// 1 validation row as its newest `qa.check` left it, joined to its `qa/report.json` row.
  public struct Row: Sendable, Equatable, Encodable {
    /// 1-based position in the plan's `validation.json`.
    public var row: Int
    public var requirement: String
    public var layer: ValidationLayer
    /// The check's text; `nil` when the report didn't read or the payload guard rejected it.
    public var check: String?
    /// The tasks the row runs after; empty when the report didn't read.
    public var runsAfter: [String]
    public var result: QAResult
    /// Why the row has its result; `nil` when the report didn't read or the guard rejected it.
    public var message: String?
    /// `nil` when the check never exited.
    public var exitStatus: Int?
    public var milliseconds: Int
    /// Run-relative paths under the `qa run`'s run directory, each passed by the payload guard.
    public var evidence: [String]
    public var waitingOn: [String]
    /// The `qa run` that checked the row last.
    public var qaRun: String
    public var at: Date
    /// The last ``RunViewValidation/maxOutputLines`` lines of a red check's saved output, each
    /// on 1 line with machine paths taken out; empty for any other result.
    public var output: [String]
    /// Whether ``output`` leaves earlier lines out.
    public var outputCut: Bool
    /// The flow the row's newest check drove, from its `qa.flow`; `nil` for a row of another
    /// layer, or a flow row that never reached its device.
    public var flow: RunViewFlow?

    public init(
      row: Int, requirement: String, layer: ValidationLayer, check: String? = nil,
      runsAfter: [String] = [], result: QAResult, message: String? = nil, exitStatus: Int? = nil,
      milliseconds: Int = 0, evidence: [String] = [], waitingOn: [String] = [], qaRun: String,
      at: Date, output: [String] = [], outputCut: Bool = false, flow: RunViewFlow? = nil
    ) {
      self.row = row
      self.requirement = requirement
      self.layer = layer
      self.check = check
      self.runsAfter = runsAfter
      self.result = result
      self.message = message
      self.exitStatus = exitStatus
      self.milliseconds = milliseconds
      self.evidence = evidence
      self.waitingOn = waitingOn
      self.qaRun = qaRun
      self.at = at
      self.output = output
      self.outputCut = outputCut
      self.flow = flow
    }
  }

  public var plan: String
  public var counts: Counts
  /// In row order.
  public var rows: [Row]
  /// The newest record of each kept XCUITest flow the run's gate runs recorded, by `[[flows]]`
  /// entry, then test.
  public var keptFlows: [RunViewKeptFlow]

  public init(
    plan: String, counts: Counts = Counts(), rows: [Row] = [], keptFlows: [RunViewKeptFlow] = []
  ) {
    self.plan = plan
    self.counts = counts
    self.rows = rows
    self.keptFlows = keptFlows
  }
}

/// 1 flow as a `qa.flow` recorded it, with every string the payload guard passed.
public struct RunViewFlow: Sendable, Equatable, Encodable {
  public struct Step: Sendable, Equatable, Encodable {
    public var n: Int
    /// `nil` when the payload guard rejected it.
    public var label: String?
    /// From the video's first frame when the flow has a video, else from the flow's start.
    public var offsetMs: Int
    public var ok: Bool

    public init(n: Int, label: String?, offsetMs: Int, ok: Bool) {
      self.n = n
      self.label = label
      self.offsetMs = offsetMs
      self.ok = ok
    }
  }

  public var source: QAFlowSource
  /// The run whose directory ``video`` and ``sheet`` are relative to: the `qa run` for a batch
  /// flow, the gate run for a kept one.
  public var run: String
  public var steps: [Step]
  /// Run-relative; `nil` when none was recorded or the guard rejected the path.
  public var video: String?
  /// Run-relative; `nil` when none was made or the guard rejected the path.
  public var sheet: String?
  public var videoUnverified: QARecordingGapReason?
  public var sheetUnverified: QARecordingGapReason?

  public init(
    source: QAFlowSource, run: String, steps: [Step] = [], video: String? = nil,
    sheet: String? = nil, videoUnverified: QARecordingGapReason? = nil,
    sheetUnverified: QARecordingGapReason? = nil
  ) {
    self.source = source
    self.run = run
    self.steps = steps
    self.video = video
    self.sheet = sheet
    self.videoUnverified = videoUnverified
    self.sheetUnverified = sheetUnverified
  }
}

/// 1 kept XCUITest flow a T3 gate run of the build run recorded.
public struct RunViewKeptFlow: Sendable, Equatable, Encodable {
  /// The `[[flows]]` entry; `nil` when the record named none or the guard rejected it.
  public var name: String?
  /// `<Class>/<method>()`; `nil` when the record named none or the guard rejected it.
  public var test: String?
  public var gateRun: String
  /// The task the gate run belongs to; `nil` when no task claims it.
  public var task: String?
  public var at: Date
  public var flow: RunViewFlow

  public init(
    name: String?, test: String?, gateRun: String, task: String? = nil, at: Date,
    flow: RunViewFlow
  ) {
    self.name = name
    self.test = test
    self.gateRun = gateRun
    self.task = task
    self.at = at
    self.flow = flow
  }
}

extension RunViewFlow.Step {
  private enum CodingKeys: String, CodingKey { case n, label, offsetMs, ok }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(n, forKey: .n)
    try c.encode(label, forKey: .label)
    try c.encode(offsetMs, forKey: .offsetMs)
    try c.encode(ok, forKey: .ok)
  }
}

extension RunViewFlow {
  private enum CodingKeys: String, CodingKey {
    case source, run, steps, video, sheet, videoUnverified, sheetUnverified
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(source, forKey: .source)
    try c.encode(run, forKey: .run)
    try c.encode(steps, forKey: .steps)
    try c.encode(video, forKey: .video)
    try c.encode(sheet, forKey: .sheet)
    try c.encode(videoUnverified, forKey: .videoUnverified)
    try c.encode(sheetUnverified, forKey: .sheetUnverified)
  }
}

extension RunViewKeptFlow {
  private enum CodingKeys: String, CodingKey { case name, test, gateRun, task, at, flow }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(name, forKey: .name)
    try c.encode(test, forKey: .test)
    try c.encode(gateRun, forKey: .gateRun)
    try c.encode(task, forKey: .task)
    try c.encode(at, forKey: .at)
    try c.encode(flow, forKey: .flow)
  }
}

extension RunViewValidation.Row {
  private enum CodingKeys: String, CodingKey {
    case row, requirement, layer, check, runsAfter, result, message, exitStatus, evidence
    case waitingOn, qaRun, at, output, outputCut, flow
    case milliseconds = "ms"
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(row, forKey: .row)
    try c.encode(requirement, forKey: .requirement)
    try c.encode(layer, forKey: .layer)
    try c.encode(check, forKey: .check)
    try c.encode(runsAfter, forKey: .runsAfter)
    try c.encode(result, forKey: .result)
    try c.encode(message, forKey: .message)
    try c.encode(exitStatus, forKey: .exitStatus)
    try c.encode(milliseconds, forKey: .milliseconds)
    try c.encode(evidence, forKey: .evidence)
    try c.encode(waitingOn, forKey: .waitingOn)
    try c.encode(qaRun, forKey: .qaRun)
    try c.encode(at, forKey: .at)
    try c.encode(output, forKey: .output)
    try c.encode(outputCut, forKey: .outputCut)
    try c.encode(flow, forKey: .flow)
  }
}

/// What the reader read of 1 `qa run`: its report and the saved output of its red rows.
public struct RunViewQARun: Sendable, Equatable {
  /// `nil` when `qa/report.json` is missing or didn't read; the reader names why in damage.
  public var report: QAReport?
  /// Each red row's evidence file's text, by its run-relative path, at most
  /// ``RunViewQARun/maxOutputBytes`` from its end.
  public var outputs: [String: String]

  /// How much of a saved output file the reader reads, from its end.
  public static let maxOutputBytes = 16 * 1024

  public init(report: QAReport? = nil, outputs: [String: String] = [:]) {
    self.report = report
    self.outputs = outputs
  }
}

/// Folds the run's `qa.check` and `qa.flow` events and the reports they name into the view's
/// validation section and its `qa.check` spans.
///
/// A run at the merge base is expected to fail every row, so it neither sets a row's result nor
/// draws a span, and its flows join nothing. A `qa.flow` with a row joins that row's check in the
/// same `qa run`; one with no row is a kept XCUITest flow of the gate run it hangs off.
enum RunViewValidationFold {
  /// - Parameter taskOfGateRun: the task each gate run belongs to, as the ledger and returns
  ///   name it.
  static func fold(
    _ events: [HarnessEvent], qaRuns: [String: RunViewQARun], roots: [String],
    taskOfGateRun: [String: String] = [:], into view: inout RunView
  ) {
    let checks = events.compactMap { event -> (event: HarnessEvent, check: QACheckEvent)? in
      guard case .qaCheck(let check) = event.payload, !check.atBase else { return nil }
      return (event, check)
    }
    var damage: [RunView.Damage] = []
    let flows = batchFlows(events, damage: &damage)
    var taskOf = taskOfGateRun
    for gate in view.gates where taskOf[gate.runID] == nil { taskOf[gate.runID] = gate.task }
    let kept = keptFlows(events, taskOf: taskOf, damage: &damage)
    guard let plan = checks.first?.check.plan ?? view.run.plan else {
      for gateRun in Set(kept.map(\.gateRun)).sorted() {
        damage.append(
          RunView.Damage(
            source: "gate run \(gateRun)", reason: "kept flows with no plan to show them under"))
      }
      view.damage += damage
      return
    }
    guard !checks.isEmpty || !kept.isEmpty else { return }
    let scrubRoots = RunViewGateFailures.Scrub.roots(roots)
    var newest: [Int: (event: HarnessEvent, check: QACheckEvent)] = [:]
    for entry in checks {
      if let seen = newest[entry.check.row], seen.event.time > entry.event.time { continue }
      newest[entry.check.row] = entry
    }
    let rows = newest.keys.sorted().compactMap { number -> RunViewValidation.Row? in
      guard let entry = newest[number] else { return nil }
      let qaRun = entry.event.runID ?? ""
      var row = row(
        entry.check, at: entry.event.time, qaRun: qaRun, read: qaRuns[qaRun], roots: scrubRoots,
        damage: &damage)
      row.flow = flows[FlowKey(qaRun: qaRun, row: number)]
      return row
    }
    var counts = RunViewValidation.Counts()
    for row in rows {
      switch row.result {
      case .pass: counts.pass += 1
      case .red: counts.red += 1
      case .unverified: counts.unverified += 1
      case .waiting: counts.waiting += 1
      case .abandoned: counts.abandoned += 1
      }
    }
    view.validation = RunViewValidation(plan: plan, counts: counts, rows: rows, keptFlows: kept)
    view.damage += damage
    let parent =
      view.spans.contains { $0.id == RunViewSpans.runSpanID } ? RunViewSpans.runSpanID : nil
    let spans = checks.compactMap { entry -> RunView.Span? in
      var span = span(entry.check, event: entry.event, parent: parent)
      span?.flow = flows[FlowKey(qaRun: entry.event.runID ?? "", row: entry.check.row)]
      return span
    }
    view.spans = (view.spans + spans).enumerated()
      .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)
  }

  private struct FlowKey: Hashable {
    var qaRun: String
    var row: Int
  }

  /// Each batch flow outside the merge base, by its `qa run` and row; the newest wins.
  private static func batchFlows(_ events: [HarnessEvent], damage: inout [RunView.Damage])
    -> [FlowKey: RunViewFlow]
  {
    var newest: [FlowKey: (time: Date, flow: QAFlowEvent)] = [:]
    for event in events {
      guard case .qaFlow(let flow) = event.payload, let row = flow.row, !flow.atBase,
        let qaRun = event.runID
      else { continue }
      let key = FlowKey(qaRun: qaRun, row: row)
      if let seen = newest[key], seen.time > event.time { continue }
      newest[key] = (event.time, flow)
    }
    var flows: [FlowKey: RunViewFlow] = [:]
    for key in newest.keys.sorted(by: { ($0.qaRun, $0.row) < ($1.qaRun, $1.row) }) {
      guard let entry = newest[key] else { continue }
      var guarded = Guarded(source: "qa run \(key.qaRun) row \(key.row)")
      flows[key] = guarded.flow(entry.flow, run: key.qaRun)
      damage += guarded.damage
    }
    return flows
  }

  /// The newest record of each kept flow, by `[[flows]]` entry and test, sorted that way.
  private static func keptFlows(
    _ events: [HarnessEvent], taskOf: [String: String], damage: inout [RunView.Damage]
  ) -> [RunViewKeptFlow] {
    var positions: [String: Int] = [:]
    var newest: [String: RunViewKeptFlow] = [:]
    var order: [String] = []
    for event in events {
      guard case .qaFlow(let flow) = event.payload, flow.row == nil, let gateRun = event.runID
      else { continue }
      let position = (positions[gateRun] ?? 0) + 1
      positions[gateRun] = position
      var guarded = Guarded(source: "gate run \(gateRun) kept flow \(position)")
      let record = RunViewKeptFlow(
        name: flow.flow.flatMap { guarded.keep($0, "flow") },
        test: flow.test.flatMap { guarded.keep($0, "test") }, gateRun: gateRun,
        task: taskOf[gateRun], at: event.time, flow: guarded.flow(flow, run: gateRun))
      damage += guarded.damage
      // A record whose names the guard dropped can't be matched to another, so it stands alone.
      let key =
        record.name != nil && record.test != nil
        ? "\(record.name ?? "")\u{0}\(record.test ?? "")" : "\(gateRun)\u{0}\(position)"
      if let seen = newest[key], seen.at > record.at { continue }
      if newest[key] == nil { order.append(key) }
      newest[key] = record
    }
    return order.compactMap { newest[$0] }.sorted {
      ($0.name ?? "\u{10FFFF}", $0.test ?? "\u{10FFFF}", $0.gateRun)
        < ($1.name ?? "\u{10FFFF}", $1.test ?? "\u{10FFFF}", $1.gateRun)
    }
  }

  /// Passes each string of 1 record through the payload guard, and each path through the
  /// run-directory check, collecting what they reject as damage under 1 source.
  private struct Guarded {
    let source: String
    var damage: [RunView.Damage] = []

    init(source: String) { self.source = source }

    mutating func keep(_ text: String, _ field: String) -> String? {
      guard let reason = EventPayloadGuard.rejection(inJSON: text) else { return text }
      damage.append(RunView.Damage(source: source, reason: "\(field): \(reason.rawValue)"))
      return nil
    }

    mutating func path(_ text: String, _ field: String) -> String? {
      guard let kept = keep(text, field) else { return nil }
      guard RunViewValidationFold.staysInRun(kept) else {
        damage.append(RunView.Damage(source: source, reason: "\(field): leaves its run directory"))
        return nil
      }
      return kept
    }

    mutating func flow(_ flow: QAFlowEvent, run: String) -> RunViewFlow {
      RunViewFlow(
        source: flow.source, run: run,
        steps: flow.steps.enumerated().map { index, step in
          RunViewFlow.Step(
            n: step.n, label: keep(step.label, "steps[\(index)].label"),
            offsetMs: step.offsetMs, ok: step.ok)
        },
        video: flow.video.flatMap { path($0, "video") },
        sheet: flow.sheet.flatMap { path($0, "sheet") },
        videoUnverified: flow.videoUnverified, sheetUnverified: flow.sheetUnverified)
    }
  }

  /// Whether `path` names a file under its run's directory: relative, with no `..` and no empty
  /// component.
  static func staysInRun(_ path: String) -> Bool {
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    return !path.hasPrefix("/") && !components.contains("..") && !components.contains("")
  }

  /// 1 row from its newest check and its report row; each string the guard rejects is dropped as
  /// a damage row.
  private static func row(
    _ check: QACheckEvent, at time: Date, qaRun: String, read: RunViewQARun?, roots: [String],
    damage: inout [RunView.Damage]
  ) -> RunViewValidation.Row {
    let source = "qa run \(qaRun) row \(check.row)"
    func keep(_ text: String, _ field: String) -> String? {
      guard let reason = EventPayloadGuard.rejection(inJSON: text) else { return text }
      damage.append(RunView.Damage(source: source, reason: "\(field): \(reason.rawValue)"))
      return nil
    }
    let reported = read?.report?.rows.first { $0.row == check.row }
    let evidence = check.evidence.enumerated().compactMap { index, path -> String? in
      guard let kept = keep(path, "evidence[\(index)]") else { return nil }
      guard staysInRun(kept) else {
        damage.append(
          RunView.Damage(source: source, reason: "evidence[\(index)]: leaves its run directory"))
        return nil
      }
      return kept
    }
    var output: [String] = []
    var cut = false
    if check.result == .red, let read {
      let lines = evidence.compactMap { read.outputs[$0] }
        .flatMap { $0.split(whereSeparator: \.isNewline) }
        .map { RunViewGateFailures.Scrub.message(String($0), roots: roots).0 }
        .filter { !$0.isEmpty }
      output = Array(lines.suffix(RunViewValidation.maxOutputLines))
      cut = lines.count > output.count
    }
    return RunViewValidation.Row(
      row: check.row, requirement: check.requirement, layer: check.layer,
      check: reported.flatMap { keep($0.check, "check") },
      runsAfter: (reported?.runsAfter ?? []).compactMap { keep($0, "runsAfter") },
      result: check.result, message: reported.flatMap { keep($0.message, "message") },
      exitStatus: check.exitStatus, milliseconds: check.milliseconds, evidence: evidence,
      waitingOn: check.waitingOn, qaRun: qaRun, at: time, output: output, outputCut: cut)
  }

  /// A check that answered, `pass` or `red`, as a span ending at its event; `nil` for a row that
  /// didn't run or ran with no answer.
  private static func span(_ check: QACheckEvent, event: HarnessEvent, parent: String?)
    -> RunView.Span?
  {
    let outcome: SpanOutcome
    switch check.result {
    case .pass: outcome = .ok
    case .red: outcome = .red
    case .unverified, .waiting, .abandoned: return nil
    }
    let how = check.exitStatus.map { " with exit \($0)" } ?? ""
    return RunView.Span(
      id: "qa:\(event.runID ?? ""):\(check.row)", parent: parent, phase: .qaCheck,
      start: event.time.addingTimeInterval(-Double(check.milliseconds) / 1000), end: event.time,
      outcome: outcome,
      failureReason: outcome == .red
        ? "Row \(check.row) \(check.layer.rawValue) check failed\(how)." : nil)
  }
}

extension RunViewValidation {
  /// Each video and contact sheet a flow links, as `<run id>/<run-relative path>`: the only files
  /// a live page may fetch from a run directory.
  public var linkedFiles: Set<String> {
    let flows = rows.compactMap(\.flow) + keptFlows.map(\.flow)
    return Set(
      flows.flatMap { flow in
        [flow.video, flow.sheet].compactMap { $0.map { "\(flow.run)/\($0)" } }
      })
  }
}

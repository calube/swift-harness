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

    public init(pass: Int = 0, red: Int = 0, unverified: Int = 0, waiting: Int = 0) {
      self.pass = pass
      self.red = red
      self.unverified = unverified
      self.waiting = waiting
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

extension RunViewValidation.Row {
  private enum CodingKeys: String, CodingKey {
    case row, requirement, layer, check, runsAfter, result, message, exitStatus, evidence
    case waitingOn, qaRun, at, output, outputCut
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

/// Folds the run's `qa.check` events and the reports they name into the view's validation
/// section and its `qa.check` spans.
///
/// A run at the merge base is expected to fail every row, so it neither sets a row's result nor
/// draws a span.
enum RunViewValidationFold {
  static func fold(
    _ events: [HarnessEvent], qaRuns: [String: RunViewQARun], roots: [String],
    into view: inout RunView
  ) {
    let checks = events.compactMap { event -> (event: HarnessEvent, check: QACheckEvent)? in
      guard case .qaCheck(let check) = event.payload, !check.atBase else { return nil }
      return (event, check)
    }
    guard let plan = checks.first?.check.plan else { return }
    let scrubRoots = RunViewGateFailures.Scrub.roots(roots)
    var newest: [Int: (event: HarnessEvent, check: QACheckEvent)] = [:]
    for entry in checks {
      if let seen = newest[entry.check.row], seen.event.time > entry.event.time { continue }
      newest[entry.check.row] = entry
    }
    var damage: [RunView.Damage] = []
    let rows = newest.keys.sorted().compactMap { number -> RunViewValidation.Row? in
      guard let entry = newest[number] else { return nil }
      let qaRun = entry.event.runID ?? ""
      return row(
        entry.check, at: entry.event.time, qaRun: qaRun, read: qaRuns[qaRun], roots: scrubRoots,
        damage: &damage)
    }
    var counts = RunViewValidation.Counts()
    for row in rows {
      switch row.result {
      case .pass: counts.pass += 1
      case .red: counts.red += 1
      case .unverified: counts.unverified += 1
      case .waiting: counts.waiting += 1
      }
    }
    view.validation = RunViewValidation(plan: plan, counts: counts, rows: rows)
    view.damage += damage
    let parent =
      view.spans.contains { $0.id == RunViewSpans.runSpanID } ? RunViewSpans.runSpanID : nil
    let spans = checks.compactMap { span($0.check, event: $0.event, parent: parent) }
    view.spans = (view.spans + spans).enumerated()
      .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)
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
    let evidence = check.evidence.enumerated().compactMap {
      keep($0.element, "evidence[\($0.offset)]")
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
    case .unverified, .waiting: return nil
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

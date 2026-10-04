import Foundation

/// How 1 of the report's inputs was read.
public enum RunReportInput<Value: Sendable & Equatable>: Sendable, Equatable {
  case read(Value)
  /// No file at `path`: nothing was recorded there.
  case missing(path: String)
  /// `source` exists but didn't decode, or couldn't be located; `reason` says which.
  case unreadable(source: String, reason: String)
}

/// A plan's newest build run: what it started with and what it recorded.
public struct RunReportBuild: Sendable, Equatable {
  public let record: BuildRunRecord
  public let log: BuildEventLog
  /// Each checked return under the run's `returns/`, by task id. A task with no entry stored no
  /// return there.
  public let returns: [String: RunReportInput<TaskReturn>]
  /// The run's `cutoff.json`; `.missing` when the cutoff never came, `nil` when not looked for.
  public let cutoff: RunReportInput<CutoffRecord>?

  public init(
    record: BuildRunRecord, log: BuildEventLog, returns: [String: RunReportInput<TaskReturn>] = [:],
    cutoff: RunReportInput<CutoffRecord>? = nil
  ) {
    self.record = record
    self.log = log
    self.returns = returns
    self.cutoff = cutoff
  }
}

/// Everything the end-of-run report reads, already loaded.
public struct BrownfieldRunReportInputs: Sendable, Equatable {
  public let slug: String
  public let planBranch: String
  /// The plan branch's head commit; `nil` when the branch doesn't exist.
  public let planBranchHead: String?
  /// `<plan-dir>/PLAN.md`'s text.
  public let plan: RunReportInput<String>
  /// `baseline/<tree>.json` at the plan branch's base tree.
  public let baseline: RunReportInput<BaselineFile>
  /// `discover/last.json`.
  public let discover: RunReportInput<DiscoverRecord>
  public let build: RunReportInput<RunReportBuild>
  /// The plan's `ledger.json`, whose task states say whether the run built everything.
  public let ledger: RunReportInput<Ledger>

  public init(
    slug: String, planBranch: String, planBranchHead: String?, plan: RunReportInput<String>,
    baseline: RunReportInput<BaselineFile>, discover: RunReportInput<DiscoverRecord>,
    build: RunReportInput<RunReportBuild>, ledger: RunReportInput<Ledger>
  ) {
    self.slug = slug
    self.planBranch = planBranch
    self.planBranchHead = planBranchHead
    self.plan = plan
    self.baseline = baseline
    self.discover = discover
    self.build = build
    self.ledger = ledger
  }
}

/// The report a brownfield run ends with (design §11.6): whether every task got done, the final
/// verdict, the unfinished tasks, the assumptions, the baseline failures, the build-only areas,
/// the dropped steps, the review fallbacks and the plan branch to merge.
public struct BrownfieldRunReport: Sendable, Equatable, Encodable {
  /// The report's file in the plan dir.
  public static let fileName = "REPORT.md"

  /// The branch `swiftgate run` creates for a plan at the user's `HEAD`.
  public static func planBranch(slug: String) -> String { "swift-harness/\(slug)" }

  /// 1 report section. `note` says why its source couldn't be read; it is `nil` when the items
  /// are the whole answer, including none.
  public struct Section<Item: Sendable & Equatable & Encodable>: Sendable, Equatable, Encodable {
    public let items: [Item]
    public let note: String?

    public init(items: [Item], note: String?) {
      self.items = items
      self.note = note
    }
  }

  public struct Final: Sendable, Equatable, Encodable {
    public let verdict: Verdict
    public let runID: String

    public init(verdict: Verdict, runID: String) {
      self.verdict = verdict
      self.runID = runID
    }
  }

  public struct BaselineFailureLine: Sendable, Equatable, Encodable {
    public let area: String
    public let step: AreaStep
    /// `nil` when the whole step failed with no test id to read.
    public let test: String?

    public init(area: String, step: AreaStep, test: String?) {
      self.area = area
      self.step = step
      self.test = test
    }
  }

  /// A ledger task the run left short of `done`.
  public struct UnfinishedTask: Sendable, Equatable, Encodable {
    public let id: String
    public let status: TaskStatus

    public init(id: String, status: TaskStatus) {
      self.id = id
      self.status = status
    }
  }

  public struct DroppedStep: Sendable, Equatable, Encodable {
    public let area: String
    public let step: AreaStep
    public let reason: String

    public init(area: String, step: AreaStep, reason: String) {
      self.area = area
      self.step = step
      self.reason = reason
    }
  }

  public let plan: String
  public let planBranch: String
  public let planBranchHead: String?
  /// The last `final` gate the plan's newest build run recorded; `nil` when none was.
  public let final: Final?
  /// Why ``final`` is `nil`, or what to know about the log it came from.
  public let finalNote: String?
  public let assumptions: Section<String>
  public let baselineFailures: Section<BaselineFailureLine>
  /// Each `## Areas` bullet of `PLAN.md` marked `build-only`, as written.
  public let buildOnlyAreas: Section<String>
  public let droppedSteps: Section<DroppedStep>
  public let reviewFallbacks: Section<String>
  /// 1 line per reviewed task: the depth its classified review ran at and what set it.
  public let reviewDepths: Section<String>
  /// Every ledger task not `done`, in ledger order. Its note says why the ledger couldn't be read,
  /// so whether the run finished is unknown.
  public let unfinishedTasks: Section<UnfinishedTask>
  /// The run's time box, then each task that didn't fit it with why; `nil` for a build run with
  /// no box.
  public let timeBox: Section<String>?

  public init(
    plan: String, planBranch: String, planBranchHead: String?, final: Final?, finalNote: String?,
    assumptions: Section<String>, baselineFailures: Section<BaselineFailureLine>,
    buildOnlyAreas: Section<String>, droppedSteps: Section<DroppedStep>,
    reviewFallbacks: Section<String>, unfinishedTasks: Section<UnfinishedTask>,
    reviewDepths: Section<String> = Section(items: [], note: nil),
    timeBox: Section<String>? = nil
  ) {
    self.plan = plan
    self.planBranch = planBranch
    self.planBranchHead = planBranchHead
    self.final = final
    self.finalNote = finalNote
    self.assumptions = assumptions
    self.baselineFailures = baselineFailures
    self.buildOnlyAreas = buildOnlyAreas
    self.droppedSteps = droppedSteps
    self.reviewFallbacks = reviewFallbacks
    self.reviewDepths = reviewDepths
    self.unfinishedTasks = unfinishedTasks
    self.timeBox = timeBox
  }

  private enum CodingKeys: String, CodingKey {
    case plan, planBranch, planBranchHead, final, finalNote, assumptions, baselineFailures
    case buildOnlyAreas, droppedSteps, reviewFallbacks, reviewDepths, unfinishedTasks, timeBox
  }

  /// Every key is always present; an absent value is `null`.
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(plan, forKey: .plan)
    try c.encode(planBranch, forKey: .planBranch)
    try c.encode(planBranchHead, forKey: .planBranchHead)
    try c.encode(final, forKey: .final)
    try c.encode(finalNote, forKey: .finalNote)
    try c.encode(assumptions, forKey: .assumptions)
    try c.encode(baselineFailures, forKey: .baselineFailures)
    try c.encode(buildOnlyAreas, forKey: .buildOnlyAreas)
    try c.encode(droppedSteps, forKey: .droppedSteps)
    try c.encode(reviewFallbacks, forKey: .reviewFallbacks)
    try c.encode(reviewDepths, forKey: .reviewDepths)
    try c.encode(unfinishedTasks, forKey: .unfinishedTasks)
    try c.encode(timeBox, forKey: .timeBox)
  }

  /// The steps `merge` and `final` run for every area: one with no command is worth a line even
  /// when nobody dropped it. Another step is listed only when the orchestrator dropped it.
  private static let reportedMissingSteps: Set<AreaStep> = [.test, .lint, .build]

  public static func make(_ inputs: BrownfieldRunReportInputs) -> BrownfieldRunReport {
    let (final, finalNote) = Self.final(inputs.build)
    let (assumptions, buildOnly) = Self.planSections(inputs.plan)
    return BrownfieldRunReport(
      plan: inputs.slug, planBranch: inputs.planBranch, planBranchHead: inputs.planBranchHead,
      final: final, finalNote: finalNote, assumptions: assumptions,
      baselineFailures: Self.baselineFailures(inputs.baseline), buildOnlyAreas: buildOnly,
      droppedSteps: Self.droppedSteps(inputs.discover, baseline: inputs.baseline),
      reviewFallbacks: Self.reviewFallbacks(inputs.build),
      unfinishedTasks: Self.unfinishedTasks(inputs.ledger),
      reviewDepths: Self.reviewDepths(inputs.build), timeBox: Self.timeBox(inputs.build))
  }

  /// The box's line, then 1 line per task the cutoff abandoned or never started. A task the
  /// cutoff let merge has no line: it either landed or shows as unfinished.
  private static func timeBox(_ build: RunReportInput<RunReportBuild>) -> Section<String>? {
    guard case .read(let run) = build, let box = run.record.timeBox else { return nil }
    let deadlines = box.deadlines
    func time(_ date: Date) -> String { date.formatted(.iso8601) }
    let source =
      switch box.limits.source {
      case .config: "[build.presets.brownfield]"
      case .flag: "--time-box"
      case .default: "the default, since the preset names no budget"
      }
    var items = [
      "\(box.limits.budgetMin) min, from \(source): launched \(time(box.startedAt)), starts stop "
        + "\(time(deadlines.noNewStartsAt)), cutoff \(time(deadlines.cutoffAt)), ends "
        + time(deadlines.endsAt)
    ]
    switch run.cutoff {
    case nil, .missing?:
      items.append("the cutoff never came")
      return Section(items: items, note: nil)
    case .unreadable(let source, let reason)?:
      return Section(
        items: items, note: "the cutoff's decisions not read from \(source): \(reason)")
    case .read(let record)?:
      for decision in record.decisions {
        switch decision.action {
        case .finishMerge: continue
        case .abandon:
          items.append("\(decision.task) didn't fit the box: abandoned, \(decision.reason)")
        case .notStarted:
          items.append("\(decision.task) didn't fit the box: \(decision.reason)")
        }
      }
      return Section(items: items, note: nil)
    }
  }

  private static func unfinishedTasks(_ ledger: RunReportInput<Ledger>) -> Section<UnfinishedTask> {
    guard case .read(let ledger) = ledger else {
      return Section(items: [], note: describe(ledger, what: "ledger"))
    }
    return Section(
      items: ledger.tasks.filter { $0.status != .done }.map {
        UnfinishedTask(id: $0.id, status: $0.status)
      }, note: nil)
  }

  private static func describe<V>(_ input: RunReportInput<V>, what: String) -> String? {
    switch input {
    case .read: nil
    case .missing(let path): "\(what) not recorded: \(path) doesn't exist"
    case .unreadable(let source, let reason): "\(what) not read from \(source): \(reason)"
    }
  }

  private static func final(_ build: RunReportInput<RunReportBuild>) -> (Final?, String?) {
    guard case .read(let run) = build else {
      return (nil, "no final gate: " + (describe(build, what: "build run") ?? ""))
    }
    let last = run.log.events.reversed().lazy.compactMap { event -> Final? in
      guard case .gate(let gate) = event, gate.stage == .final else { return nil }
      return Final(verdict: gate.verdict, runID: gate.runID)
    }.first
    let damage =
      run.log.damage.isEmpty
      ? nil
      : "build run \(run.record.runID)'s event log has \(run.log.damage.count) unreadable line(s)"
    guard let last else {
      return (
        nil,
        "no final gate: build run \(run.record.runID) recorded none"
          + (damage.map { "; \($0)" } ?? "")
      )
    }
    return (last, damage.map { "\($0), so a later final gate may be lost" })
  }

  private static func planSections(_ plan: RunReportInput<String>)
    -> (assumptions: Section<String>, buildOnly: Section<String>)
  {
    guard case .read(let text) = plan else {
      let note = describe(plan, what: "PLAN.md")
      return (Section(items: [], note: note), Section(items: [], note: note))
    }
    let assumptions = bullets(under: "Assumptions", in: text)
    let areas = bullets(under: "Areas", in: text)
    return (
      Section(
        items: assumptions ?? [],
        note: assumptions == nil ? "PLAN.md has no `## Assumptions` section" : nil),
      Section(
        items: (areas ?? []).filter { isBuildOnly($0) },
        note: areas == nil
          ? "PLAN.md has no `## Areas` section, so no area is known build-only" : nil)
    )
  }

  /// The bullets of `PLAN.md`'s `## <title>` section, each continuation line joined to its
  /// bullet; `nil` when there is no such section.
  private static func bullets(under title: String, in text: String) -> [String]? {
    var inside = false
    var seen = false
    var items: [String] = []
    for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
      let line = String(raw)
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("#") {
        inside =
          line.hasPrefix("## ")
          && trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
            == title.lowercased()
        seen = seen || inside
        continue
      }
      guard inside, !trimmed.isEmpty else { continue }
      if line.hasPrefix("- ") {
        items.append(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
      } else if let last = items.popLast() {
        items.append(last + " " + trimmed)
      }
    }
    return seen ? items : nil
  }

  private static func isBuildOnly(_ bullet: String) -> Bool {
    bullet.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "-" }).contains("build-only")
  }

  private static func baselineFailures(_ baseline: RunReportInput<BaselineFile>)
    -> Section<BaselineFailureLine>
  {
    guard case .read(let file) = baseline else {
      return Section(items: [], note: describe(baseline, what: "baseline"))
    }
    // A step re-recorded under an edited command keeps its earlier record, so 1 failing test can
    // appear once per command.
    var seen: Set<String> = []
    var lines: [BaselineFailureLine] = []
    for failure in file.records.flatMap({ Baseline.failures(of: $0.key, $0.result) }) {
      let line = BaselineFailureLine(
        area: failure.key.area, step: failure.key.step, test: failure.test)
      let identity = [line.area, line.step.rawValue, line.test.map { "test:" + $0 } ?? "step"]
      guard seen.insert(identity.joined(separator: "\u{0}")).inserted else { continue }
      lines.append(line)
    }
    return Section(
      items: lines.sorted {
        ($0.area, $0.step.rawValue, $0.test ?? "") < ($1.area, $1.step.rawValue, $1.test ?? "")
      }, note: nil)
  }

  /// The steps discovery or the orchestrator dropped, then each step the baseline found not
  /// installed, which checked nothing.
  private static func droppedSteps(
    _ discover: RunReportInput<DiscoverRecord>, baseline: RunReportInput<BaselineFile>
  ) -> Section<DroppedStep> {
    var dropped: [DroppedStep] = []
    if case .read(let file) = baseline {
      var seen: Set<String> = []
      for record in file.records where record.result == .notInstalled {
        guard seen.insert("\(record.key.area).\(record.key.step.rawValue)").inserted else {
          continue
        }
        dropped.append(
          DroppedStep(
            area: record.key.area, step: record.key.step,
            reason:
              "its command's tool isn't installed (exit 127 at the base tree), so it checked "
              + "nothing"))
      }
    }
    guard case .read(let record) = discover else {
      return Section(items: dropped, note: describe(discover, what: "discover record"))
    }
    var byEdit: Set<String> = []
    for edit in record.edits {
      guard case .drop(let reason) = edit.change else { continue }
      byEdit.insert("\(edit.area).\(edit.step.rawValue)")
      dropped.append(DroppedStep(area: edit.area, step: edit.step, reason: reason))
    }
    for area in record.proposal.areas {
      for (step, reason) in area.missing
      where reportedMissingSteps.contains(step)
        && !byEdit.contains("\(area.name).\(step.rawValue)")
      {
        dropped.append(DroppedStep(area: area.name, step: step, reason: reason))
      }
    }
    return Section(
      items: dropped.sorted { ($0.area, $0.step.rawValue) < ($1.area, $1.step.rawValue) },
      note: nil)
  }

  /// Classified review takes each task's depth from `judge diff-risk`, and `build-task.js` puts
  /// the depth and its source in the return's `notes` as 1 line starting with this.
  static let classifiedNotePrefix = "review: classified at "
  /// How the line ends when the judge rated the change.
  static let ratedNoteSuffix = " by swiftgate judge diff-risk"
  /// How the line continues after `high` when a changed path matched a sensitive glob: then
  /// `<glob> matches <path>`.
  static let sensitiveNoteInfix = " because the sensitive glob "
  /// What separates the glob from the path in a sensitive line.
  static let sensitiveNoteMatches = " matches "
  /// How the line continues after `medium` when diff-risk gave no level.
  static let fallbackNoteInfix = ", because diff-risk gave no level ("

  /// What a reviewed task's return says about its classified review's depth.
  private enum DepthReading {
    case judged(DiffRiskLevel)
    case sensitive(glob: String, path: String)
    /// Ran at `medium`, because diff-risk gave no level.
    case fellBack(why: String)
    case unknown(String)
    /// The task stopped before review, as a design conflict or a red gate does.
    case notReviewed
  }

  /// Each task the build carried through review, in the order the log first names it, with the
  /// state that shows it was reviewed. A task the build carried through review is one it merged,
  /// or one it started that ended blocked or needing a replan, since a return halts only after
  /// its review; a task marked done with no merge was landed without one.
  private static func reviewedTasks(_ run: RunReportBuild) -> [(task: String, state: String)] {
    var order: [String] = []
    var merged: Set<String> = []
    var ended: [String: TaskStatus] = [:]
    for event in run.log.events {
      switch event {
      case .merge(let merge):
        merged.insert(merge.task)
        if !order.contains(merge.task) { order.append(merge.task) }
      case .transition(let transition) where transition.from == .inProgress:
        ended[transition.task] = transition.to
        if !order.contains(transition.task) { order.append(transition.task) }
      case .transition, .undo, .gate, .returnCheck:
        continue
      }
    }
    return order.compactMap { task in
      if merged.contains(task) { return (task, "merged") }
      if let status = ended[task], [.blocked, .needsReplan].contains(status) {
        return (task, status.rawValue)
      }
      return nil
    }
  }

  /// 1 line per reviewed task whose classified review didn't run at the depth diff-risk rated:
  /// it fell back to `medium`, saying why, or its depth is unknown because its return is missing,
  /// unreadable or silent.
  private static func reviewFallbacks(_ build: RunReportInput<RunReportBuild>) -> Section<String> {
    guard case .read(let run) = build else {
      return Section(items: [], note: describe(build, what: "build run"))
    }
    guard run.record.preset.review == .classified else { return Section(items: [], note: nil) }
    let items = reviewedTasks(run).compactMap { task, state -> String? in
      let why: String
      switch depth(run.returns[task]) {
      case .judged, .sensitive, .notReviewed: return nil
      case .fellBack(let reason):
        why = "classified review ran at medium, because diff-risk gave no level: \(reason)"
      case .unknown(let reason): why = "review depth unknown: \(reason)"
      }
      return "\(task) (\(state)): \(why)"
    }
    return Section(items: items, note: nil)
  }

  /// 1 line per reviewed task: the depth its classified review ran at and what set it.
  private static func reviewDepths(_ build: RunReportInput<RunReportBuild>) -> Section<String> {
    guard case .read(let run) = build else {
      return Section(items: [], note: describe(build, what: "build run"))
    }
    let review = run.record.preset.review
    guard review == .classified else {
      return Section(
        items: [], note: "the preset's review is \(review.rawValue), so no task was classified")
    }
    let items = reviewedTasks(run).compactMap { task, state -> String? in
      let depth: String
      switch Self.depth(run.returns[task]) {
      case .judged(let level): depth = "\(level.rawValue), as swiftgate judge diff-risk rated it"
      case .sensitive(let glob, let path):
        depth = "\(DiffRiskLevel.high.rawValue), because the sensitive glob \(glob) matches \(path)"
      case .fellBack(let why):
        depth = "\(DiffRiskLevel.medium.rawValue), because diff-risk gave no level: \(why)"
      case .unknown(let why): depth = "unknown, \(why)"
      case .notReviewed: return nil
      }
      return "\(task) (\(state)): \(depth)"
    }
    return Section(items: items, note: nil)
  }

  /// What a task's return says its classified review's depth was.
  private static func depth(_ input: RunReportInput<TaskReturn>?) -> DepthReading {
    let taskReturn: TaskReturn
    switch input {
    case nil:
      return .unknown("the build run stored no checked return for it")
    case .missing(let path)?:
      return .unknown("\(path) doesn't exist")
    case .unreadable(let source, let reason)?:
      return .unknown("\(source) didn't read: \(reason)")
    case .read(let read)?:
      taskReturn = read
    }
    let line = taskReturn.notes.split(separator: "\n").last { $0.hasPrefix(classifiedNotePrefix) }
    guard let line else {
      if [.designConflict, .gateRed].contains(taskReturn.outcome) { return .notReviewed }
      return .unknown("its return's notes name no classified depth")
    }
    let rest = line.dropFirst(classifiedNotePrefix.count)
    if rest.hasSuffix(ratedNoteSuffix),
      let level = DiffRiskLevel(rawValue: String(rest.dropLast(ratedNoteSuffix.count)))
    {
      return .judged(level)
    }
    let sensitive = DiffRiskLevel.high.rawValue + sensitiveNoteInfix
    if rest.hasPrefix(sensitive),
      let split = rest.dropFirst(sensitive.count).range(of: sensitiveNoteMatches)
    {
      let match = rest.dropFirst(sensitive.count)
      let glob = String(match[..<split.lowerBound])
      let path = String(match[split.upperBound...])
      if !glob.isEmpty, !path.isEmpty { return .sensitive(glob: glob, path: path) }
    }
    let medium = DiffRiskLevel.medium.rawValue + fallbackNoteInfix
    if rest.hasPrefix(medium), rest.hasSuffix(")") {
      return .fellBack(why: String(rest.dropFirst(medium.count).dropLast()))
    }
    return .unknown("its return's review line doesn't read as a depth: \(line)")
  }

  /// The report as Markdown. A run that left a task short of `done`, or whose ledger couldn't be
  /// read, says so on its first line, since `final` gates only what merged; the final verdict
  /// follows.
  public var text: String {
    var out: [String] = []
    var scope = ""
    if let note = unfinishedTasks.note {
      out.append("run: completeness unknown; \(note)")
      scope = ", gating only what merged"
    } else if !unfinishedTasks.items.isEmpty {
      let tasks = unfinishedTasks.items.map { "\($0.id) (\($0.status.rawValue))" }
      out.append(
        "run: INCOMPLETE, \(tasks.count) task(s) not done: " + tasks.joined(separator: ", "))
      scope = ", gating only what merged"
    }
    if let final {
      out.append("final: \(final.verdict.rawValue) (gate run \(final.runID))\(scope)")
    } else {
      out.append("final: not recorded; \(finalNote ?? "no final gate")")
    }
    out.append("")
    out.append("# Run report: \(plan)")
    if let final, let finalNote {
      out += ["", "Note: \(finalNote) (final \(final.verdict.rawValue))"]
    }
    out += render("Unfinished tasks", unfinishedTasks) { "\($0.id): \($0.status.rawValue)" }
    if let timeBox { out += render("Time box", timeBox) { $0 } }
    out += render("Assumptions", assumptions) { $0 }
    out += render("Baseline failures", baselineFailures) {
      "\($0.area) \($0.step.rawValue): " + ($0.test ?? "the whole step")
    }
    out += render("Build-only areas", buildOnlyAreas) { $0 }
    out += render("Dropped steps", droppedSteps) {
      "\($0.area) \($0.step.rawValue): \($0.reason)"
    }
    out += render("Review depth", reviewDepths) { $0 }
    out += render("Review fallbacks", reviewFallbacks) { $0 }
    out += ["", "## Plan branch", ""]
    if let planBranchHead {
      out.append(
        "- \(planBranch) at \(planBranchHead) holds every commit of the run; merging it is your call"
      )
    } else {
      out.append("- \(planBranch) doesn't exist, so the run left nothing to merge")
    }
    return out.joined(separator: "\n") + "\n"
  }

  private func render<Item>(_ title: String, _ section: Section<Item>, _ line: (Item) -> String)
    -> [String]
  {
    var out = ["", "## \(title)", ""]
    out += section.items.map { "- " + line($0) }
    if let note = section.note { out.append("- " + note) }
    if section.items.isEmpty, section.note == nil { out.append("- none") }
    return out
  }
}

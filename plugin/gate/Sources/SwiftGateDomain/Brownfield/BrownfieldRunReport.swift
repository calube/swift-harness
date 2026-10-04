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

  public init(record: BuildRunRecord, log: BuildEventLog) {
    self.record = record
    self.log = log
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

/// The report a brownfield run ends with (design §11.6): the final verdict, the assumptions, the
/// baseline failures, the build-only areas, the dropped steps, the review fallbacks and the plan
/// branch to merge.
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
  /// Every ledger task not `done`, in ledger order. Its note says why the ledger couldn't be read,
  /// so whether the run finished is unknown.
  public let unfinishedTasks: Section<UnfinishedTask>

  public init(
    plan: String, planBranch: String, planBranchHead: String?, final: Final?, finalNote: String?,
    assumptions: Section<String>, baselineFailures: Section<BaselineFailureLine>,
    buildOnlyAreas: Section<String>, droppedSteps: Section<DroppedStep>,
    reviewFallbacks: Section<String>, unfinishedTasks: Section<UnfinishedTask>
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
    self.unfinishedTasks = unfinishedTasks
  }

  private enum CodingKeys: String, CodingKey {
    case plan, planBranch, planBranchHead, final, finalNote, assumptions, baselineFailures
    case buildOnlyAreas, droppedSteps, reviewFallbacks
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
      droppedSteps: Self.droppedSteps(inputs.discover),
      reviewFallbacks: Self.reviewFallbacks(inputs.build),
      unfinishedTasks: Section(items: [], note: nil))
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
    let failures = file.records.flatMap { Baseline.failures(of: $0.key, $0.result) }
    let lines = failures.map {
      BaselineFailureLine(area: $0.key.area, step: $0.key.step, test: $0.test)
    }
    return Section(
      items: lines.sorted {
        ($0.area, $0.step.rawValue, $0.test ?? "") < ($1.area, $1.step.rawValue, $1.test ?? "")
      }, note: nil)
  }

  private static func droppedSteps(_ discover: RunReportInput<DiscoverRecord>)
    -> Section<DroppedStep>
  {
    guard case .read(let record) = discover else {
      return Section(items: [], note: describe(discover, what: "discover record"))
    }
    var dropped: [DroppedStep] = []
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

  /// The build-task workflow gets no diff-risk answer, so classified review runs every task at
  /// `medium`; the report names them so the depth is never silent.
  private static func reviewFallbacks(_ build: RunReportInput<RunReportBuild>) -> Section<String> {
    guard case .read(let run) = build else {
      return Section(items: [], note: describe(build, what: "build run"))
    }
    guard run.record.preset.review == .classified else { return Section(items: [], note: nil) }
    var merged: [String] = []
    for case .merge(let merge) in run.log.events where !merged.contains(merge.task) {
      merged.append(merge.task)
    }
    guard !merged.isEmpty else { return Section(items: [], note: nil) }
    return Section(
      items: [
        "classified review ran at medium for \(merged.count) merged task(s), because no "
          + "diff-risk answer reached them: " + merged.joined(separator: ", ")
      ], note: nil)
  }

  /// The report as Markdown, the final verdict on its first line.
  public var text: String {
    var out: [String] = []
    if let final {
      out.append("final: \(final.verdict.rawValue) (gate run \(final.runID))")
    } else {
      out.append("final: not recorded; \(finalNote ?? "no final gate")")
    }
    out.append("")
    out.append("# Run report: \(plan)")
    if let final, let finalNote {
      out += ["", "Note: \(finalNote) (final \(final.verdict.rawValue))"]
    }
    out += render("Assumptions", assumptions) { $0 }
    out += render("Baseline failures", baselineFailures) {
      "\($0.area) \($0.step.rawValue): " + ($0.test ?? "the whole step")
    }
    out += render("Build-only areas", buildOnlyAreas) { $0 }
    out += render("Dropped steps", droppedSteps) {
      "\($0.area) \($0.step.rawValue): \($0.reason)"
    }
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

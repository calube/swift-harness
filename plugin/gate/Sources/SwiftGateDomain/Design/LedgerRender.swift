import Foundation

/// The ledger page a plan's tasks render to (spec §6.2 D21): the task DAG as a Mermaid
/// `flowchart`, the wave timeline in ``PlanSchedule`` order, a requirement × task coverage matrix
/// and the predicted overhead share. Reuses ``ArtifactPageShell`` and ``HTMLEscape``: no second
/// shell or escaper for a second kind of rendered page.
public enum LedgerRender {
  public struct Input: Sendable, Equatable {
    public let slug: String
    public let ledger: Ledger
    /// The design at the plan's `designSha` (spec §5.4): never the working tree.
    public let design: DesignDocument
    public let designSha: String
    /// This plan's build run metrics, when one exists; `nil` renders the wave timeline exactly as
    /// it did before durations existed.
    public let buildMetrics: BuildMetrics.Report?

    public init(
      slug: String, ledger: Ledger, design: DesignDocument, designSha: String,
      buildMetrics: BuildMetrics.Report? = nil
    ) {
      self.slug = slug
      self.ledger = ledger
      self.design = design
      self.designSha = designSha
      self.buildMetrics = buildMetrics
    }
  }

  /// A read-only view: unlike the design page's approval bar, nothing here writes to the page's
  /// `db`, so no capability is declared.
  public static let capabilities: [ArtifactCapability] = []

  public static func page(_ input: Input) -> ArtifactPageShell {
    let tasks = input.ledger.tasks
    let schedule = PlanSchedule.schedule(tasks: tasks, maxParallel: input.ledger.maxParallel)

    let body: [HTMLFragment] = [
      header(slug: input.slug, designSha: input.designSha),
      dagSection(tasks: tasks),
      waveSection(ledger: input.ledger, schedule: schedule, buildMetrics: input.buildMetrics),
      matrixSection(design: input.design, tasks: tasks),
      overheadSection(tasks: tasks, schedule: schedule),
    ]

    return ArtifactPageShell(
      title: "Ledger: \(input.slug)", body: .joined(body), capabilities: capabilities)
  }

  // MARK: - Header

  static func header(slug: String, designSha: String) -> HTMLFragment {
    let chip = HTMLFragment.element(
      "span", attributes: ["class": "chip", "title": designSha],
      text: "Revision \(designSha.prefix(10))")
    return .element(
      "header", attributes: ["class": "masthead"],
      [
        .element("h1", text: "Ledger: \(slug)"),
        .element("div", attributes: ["class": "meta"], [chip]),
      ])
  }

  // MARK: - Task DAG

  /// One Mermaid node per task, id `n<i>` over tasks sorted by id — never the task's own id, so an
  /// arbitrary task id never has to double as a syntactically valid Mermaid identifier. Edges are
  /// exactly `deps`: for every task, one `n<depIndex> --> n<taskIndex>` per dependency, nothing
  /// else, so an edge list read back from this text equals the ledger's `deps` exactly.
  public static func dagMermaidSource(tasks: [LedgerTask]) -> String {
    let sorted = tasks.sorted { $0.id < $1.id }
    let indexOf = Dictionary(
      sorted.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
    var lines = ["flowchart LR"]
    for (index, task) in sorted.enumerated() {
      lines.append("  n\(index)[\"\(MermaidLabel.escape(task.id))\"]")
    }
    for task in sorted {
      guard let to = indexOf[task.id] else { continue }
      for dependency in task.deps.sorted() {
        guard let from = indexOf[dependency] else { continue }
        lines.append("  n\(from) --> n\(to)")
      }
    }
    return lines.joined(separator: "\n")
  }

  static func dagSection(tasks: [LedgerTask]) -> HTMLFragment {
    section(
      "Task DAG",
      [
        .element(
          "figure",
          [
            .element(
              "pre", attributes: ["class": "mermaid"], text: dagMermaidSource(tasks: tasks))
          ])
      ])
  }

  // MARK: - Wave timeline

  /// `plan-lint` already gates a stored `waves` that doesn't match this recomputation (spec §9.2);
  /// this page still checks it itself and shows the recomputed order with a visible warning
  /// instead of trusting either side silently — a page can be rendered from a ledger `plan-lint`
  /// hasn't re-checked since a hand edit.
  static func waveSection(
    ledger: Ledger, schedule: Result<[[String]], PlanSchedule.ScheduleError>,
    buildMetrics: BuildMetrics.Report? = nil
  ) -> HTMLFragment {
    switch schedule {
    case .failure(let error):
      return section(
        "Wave timeline",
        [
          .element(
            "p", attributes: ["class": "cite"],
            text: "Wave timeline unavailable: \(describe(error)).")
        ])
    case .success(let waves):
      var content: [HTMLFragment] = []
      if waves != ledger.waves {
        content.append(
          .element(
            "p", attributes: ["class": "cite"],
            text:
              "Warning: ledger.json's stored wave order doesn't match plan-schedule's recomputed "
              + "output; showing the recomputed order below."))
      }
      let statusByID = Dictionary(
        ledger.tasks.map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first })
      let durationByID = Dictionary(
        (buildMetrics?.taskDurations ?? []).map { ($0.task, $0.wallMilliseconds) },
        uniquingKeysWith: { first, _ in first })
      let rows = waves.enumerated().map { index, wave in
        HTMLFragment.element(
          "tr", attributes: ["data-wave": String(index)],
          [
            .element("th", attributes: ["scope": "row"], text: "Wave \(index + 1)"),
            .element(
              "td",
              [
                .element(
                  "ul",
                  wave.map {
                    taskListItem(
                      id: $0, status: statusByID[$0], wallMilliseconds: durationByID[$0])
                  })
              ]),
          ])
      }
      content.append(
        .element(
          "div", attributes: ["class": "scroll"],
          [
            .element(
              "table",
              [
                .element(
                  "thead",
                  [
                    .element(
                      "tr", [.element("th", text: "Wave"), .element("th", text: "Tasks")])
                  ]),
                .element("tbody", rows),
              ])
          ]))
      return section("Wave timeline", content)
    }
  }

  /// A wave list entry: the task id, plus a status badge whose visible text (not colour alone)
  /// distinguishes every state — `blocked` and `abandoned` included, and from each other. `status`
  /// is `nil` for a task id the wave names but the ledger's `tasks` list doesn't (only reachable
  /// from a hand-edited ledger; the id still renders, with no badge). `wallMilliseconds` renders a
  /// duration chip only when given, so a page built without build metrics is unchanged.
  static func taskListItem(id: String, status: TaskStatus?, wallMilliseconds: Int? = nil)
    -> HTMLFragment
  {
    let statusValue = status?.rawValue ?? "unknown"
    var children: [HTMLFragment] = [.element("span", attributes: ["class": "task-id"], text: id)]
    if let status {
      children.append(
        .element(
          "span", attributes: ["class": "status-badge", "data-status": statusValue],
          text: statusLabel(status)))
    }
    if let wallMilliseconds {
      children.append(
        .element(
          "span", attributes: ["class": "task-duration"],
          text: ReportRenderer.duration(wallMilliseconds)))
    }
    return .element("li", attributes: ["data-status": statusValue], children)
  }

  public static func statusLabel(_ status: TaskStatus) -> String {
    switch status {
    case .pending: "Pending"
    case .inProgress: "In progress"
    case .done: "Done"
    case .needsReplan: "Needs replan"
    case .blocked: "Blocked"
    case .abandoned: "Abandoned"
    }
  }

  public static func describe(_ error: PlanSchedule.ScheduleError) -> String {
    switch error {
    case .cycle(let ids): "the tasks \(ids.joined(separator: " → ")) form a dependency cycle"
    case .missingDependency(let task, let dependency):
      "task \(task) depends on \(dependency), which isn't in the ledger"
    case .duplicateTaskID(let ids):
      ids.map { "task id \($0) appears more than once" }.joined(separator: "; ")
    }
  }

  // MARK: - Requirement × task coverage matrix

  /// Every design requirement is a row; ``PlanLintCoverage/uncoveredIDs(design:tasks:)`` decides
  /// which ones are a gap — the same function `plan-lint` gates on, never a re-implementation of
  /// it. A gap is a visible "Coverage" cell reading "Gap", not a colour: a reader scanning the
  /// column of text sees it even in a printed or colour-blind view.
  static func matrixSection(design: DesignDocument, tasks: [LedgerTask]) -> HTMLFragment {
    let sortedTasks = tasks.sorted { $0.id < $1.id }
    let uncovered = Set(PlanLintCoverage.uncoveredIDs(design: design, tasks: tasks))
    let head = HTMLFragment.element(
      "tr",
      [.element("th", text: "Requirement")] + sortedTasks.map { .element("th", text: $0.id) }
        + [.element("th", text: "Coverage")])
    let rows = design.requirements.map { requirement -> HTMLFragment in
      let isGap = uncovered.contains(requirement.id)
      let cells = sortedTasks.map { task in
        HTMLFragment.element("td", text: task.covers.contains(requirement.id) ? "Covered" : "")
      }
      let coverage = HTMLFragment.element(
        "td", attributes: ["data-gap": isGap ? "true" : "false"],
        text: isGap ? "Gap: no task covers this" : "Covered")
      return .element(
        "tr", attributes: ["data-requirement": requirement.id],
        [.element("th", attributes: ["scope": "row"], text: requirement.statement)] + cells
          + [coverage])
    }
    return section(
      "Requirement × task coverage",
      [
        .element(
          "div", attributes: ["class": "scroll"],
          [.element("table", [.element("thead", [head]), .element("tbody", rows)])])
      ])
  }

  // MARK: - Predicted overhead share

  static func overheadSection(
    tasks: [LedgerTask], schedule: Result<[[String]], PlanSchedule.ScheduleError>
  ) -> HTMLFragment {
    switch schedule {
    case .failure(let error):
      return section(
        "Predicted overhead share",
        [.element("p", text: "Unavailable: \(describe(error)).")])
    case .success(let waves):
      guard let share = predictedOverheadShare(tasks: tasks, waves: waves) else {
        return section(
          "Predicted overhead share", [.element("p", text: "n/a (no tasks or no estimated time)")]
        )
      }
      let percent = Int((share * 100).rounded())
      return section(
        "Predicted overhead share",
        [.element("p", text: "\(percent)% predicted overhead beyond the critical path.")])
    }
  }

  /// The spec names this metric (§9.3: "`stats` reports estimate error … and overhead share") but
  /// gives no formula — this is this task's own choice, reported as a DEVIATION.
  ///
  /// `wall` = Σ over the recomputed schedule's waves of `max(estLines)` of that wave's tasks: a
  /// wave's predicted duration is bounded by its slowest task, and waves run one after another.
  /// `criticalPath` = the longest `estLines`-weighted chain through the dependency DAG: the least
  /// wall time even an unlimited number of parallel workers could reach, since a dependent task
  /// can never start before its deepest dependency chain finishes.
  /// `overheadShare = (wall − criticalPath) / wall`; `nil` ("n/a") when there are no tasks or
  /// `wall` is 0.
  ///
  /// It is always ≥ 0: dependencies force a chain's tasks into strictly increasing layers, so the
  /// waves the chain's tasks land in are pairwise distinct; those waves alone already sum to at
  /// least `criticalPath`, and `wall` only adds more from every other wave.
  public static func predictedOverheadShare(tasks: [LedgerTask], waves: [[String]]) -> Double? {
    guard !tasks.isEmpty else { return nil }
    let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let wall = waves.reduce(0) { sum, wave in
      sum + (wave.compactMap { byID[$0]?.estLines }.max() ?? 0)
    }
    guard wall > 0 else { return nil }
    return Double(wall - criticalPathLines(tasks: tasks, byID: byID)) / Double(wall)
  }

  /// The longest `estLines`-weighted path ending at any task, over the whole set. A cycle can't
  /// reach this function through ``page(_:)`` (the wave section already reports it and skips this
  /// one instead), so the zero seeded before recursing is only a safety net for a caller that
  /// hands in cyclic tasks directly.
  static func criticalPathLines(tasks: [LedgerTask], byID: [String: LedgerTask]) -> Int {
    var memo: [String: Int] = [:]
    func longest(_ id: String) -> Int {
      if let cached = memo[id] { return cached }
      guard let task = byID[id] else { return 0 }
      memo[id] = 0
      let value = (task.deps.map(longest).max() ?? 0) + task.estLines
      memo[id] = value
      return value
    }
    return tasks.map { longest($0.id) }.max() ?? 0
  }

  // MARK: - Building blocks

  static func section(_ heading: String, _ content: [HTMLFragment]) -> HTMLFragment {
    .element("section", [.element("h2", text: heading)] + content)
  }
}

/// Escapes a task id for use inside a Mermaid node label. Only letters, digits, spaces and a
/// lone `-` pass through unchanged (a single hyphen is inert in every Mermaid or HTML grammar);
/// everything else — brackets, quotes, angle brackets, the arrow's `>`, parens — becomes its
/// decimal character reference (Mermaid's own escape convention for label text, e.g. `#93;` for
/// `]`), so a task id can never reopen Mermaid's own grammar (closing a node early, forging an
/// edge) or, once Mermaid's `htmlLabels` renders the label, reach the page as live markup.
enum MermaidLabel {
  static func escape(_ text: String) -> String {
    var result = ""
    result.reserveCapacity(text.unicodeScalars.count)
    for scalar in text.unicodeScalars {
      switch scalar {
      case "a"..."z", "A"..."Z", "0"..."9", " ", "-":
        result.unicodeScalars.append(scalar)
      default:
        result += "#\(scalar.value);"
      }
    }
    return result
  }
}

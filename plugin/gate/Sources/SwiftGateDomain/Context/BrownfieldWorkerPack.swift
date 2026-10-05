import Foundation

/// A worker's pack in a brownfield clone, which has no design, no module graph and no owned
/// standards: the task's ledger entry, its `PLAN.md` section and the plan's assumptions, the
/// config areas its write set lies in with their commands, and the harness's brownfield rules.
public struct BrownfieldWorkerInputs: Sendable, Equatable {
  public let task: LedgerTask
  /// The plan's live `PLAN.md`.
  public let plan: ContextSource
  /// Every area `config.toml` holds; the pack keeps the ones the task's write set lies in.
  public let areas: [BrownfieldArea]
  /// The harness's `docs/standards.md`, whose brownfield profile section holds the rules.
  public let standards: ContextSource
  public let dependencyNotes: [DependencyReturnNotes]
  /// The review findings other tasks deferred that this task's worker writes the test for.
  public let deferred: [DeferredFinding]
  /// The clone's state layout, which places each swiftpm area's shared scratch path; `nil` leaves
  /// the pack without a build-only line.
  public let layout: BrownfieldStateLayout?

  public init(
    task: LedgerTask, plan: ContextSource, areas: [BrownfieldArea], standards: ContextSource,
    dependencyNotes: [DependencyReturnNotes], deferred: [DeferredFinding] = [],
    layout: BrownfieldStateLayout? = nil
  ) {
    self.task = task
    self.plan = plan
    self.areas = areas
    self.standards = standards
    self.dependencyNotes = dependencyNotes
    self.deferred = deferred
    self.layout = layout
  }
}

extension ContextPack {
  /// The heading the brownfield rules' section of the standards doc starts with.
  public static let brownfieldRulesHeading = "Brownfield profile"

  /// The task's ledger entry; its `PLAN.md` section and the plan's Assumptions, verbatim; each
  /// area its write set lies in, with that area's commands as `config.toml` holds them; the
  /// standards doc's brownfield profile section, verbatim; and its dependencies' return notes.
  /// A task whose write set lies in no area says so, so an empty section is never a lost one.
  public static func brownfieldWorkerPack(_ inputs: BrownfieldWorkerInputs) throws -> ContextPack {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    var slices = [
      ContextPackSlice(
        sourceLabel: "ledger task entry: \(inputs.task.id)", anchor: nil,
        lines: MarkdownAnchorSlicer.rawLines(
          String(decoding: try encoder.encode(inputs.task), as: UTF8.self)))
    ]

    let plan = MarkdownDocument.parse(inputs.plan.rawText)
    slices.append(
      try MarkdownAnchorSlicer.slice(
        anchor: inputs.task.id, of: plan, rawText: inputs.plan.rawText,
        sourceLabel: inputs.plan.label))
    if plan.section(anchor: "assumptions") != nil {
      // The plan's task sections nest under its last `##` section, Assumptions, so the slice
      // stops at the first heading below it: another task's section never rides along.
      let whole = try MarkdownAnchorSlicer.slice(
        anchor: "assumptions", of: plan, rawText: inputs.plan.rawText,
        sourceLabel: inputs.plan.label)
      let body = whole.lines.dropFirst().prefix { !$0.hasPrefix("#") }
      slices.append(
        ContextPackSlice(
          sourceLabel: whole.sourceLabel, anchor: whole.anchor,
          lines: Array(whole.lines.prefix(1) + body)))
    }

    let held = areas(holding: inputs.task.writeSet, in: inputs.areas)
    if held.isEmpty {
      slices.append(
        ContextPackSlice(
          sourceLabel: "config.toml areas", anchor: nil,
          lines: ["No area in config.toml holds this task's write set; no area commands apply."]))
    }
    for area in held {
      slices.append(
        ContextPackSlice(
          sourceLabel: "config.toml area \(area.name)", anchor: nil,
          lines: areaLines(area) + workerCommandLines(area, layout: inputs.layout)))
    }

    let standards = MarkdownDocument.parse(inputs.standards.rawText)
    guard
      let rules = sections(standards.sections).first(where: {
        $0.heading.hasPrefix(brownfieldRulesHeading)
      })
    else {
      throw ContextPackError.missingAnchor(
        anchor: brownfieldRulesHeading, source: inputs.standards.label)
    }
    slices.append(
      try MarkdownAnchorSlicer.slice(
        anchor: rules.anchor, of: standards, rawText: inputs.standards.rawText,
        sourceLabel: inputs.standards.label))

    if !inputs.dependencyNotes.isEmpty {
      var noteLines: [String] = []
      for dependency in inputs.dependencyNotes {
        guard let notes = dependency.notes else {
          throw ContextPackError.missingDependencyReturn(task: dependency.taskID)
        }
        noteLines.append(dependency.taskID)
        noteLines.append(contentsOf: MarkdownAnchorSlicer.rawLines(notes))
      }
      slices.append(
        ContextPackSlice(
          sourceLabel: "Notes from the tasks this one depends on", anchor: nil, lines: noteLines))
    }
    if let deferred = deferredSlice(inputs.deferred) { slices.append(deferred) }
    return ContextPack(role: .worker, slices: slices)
  }

  /// The deferrals a task owns, each a test its worker writes; `nil` when it owns none.
  static func deferredSlice(_ deferred: [DeferredFinding]) -> ContextPackSlice? {
    guard !deferred.isEmpty else { return nil }
    return ContextPackSlice(
      sourceLabel: "\(DeferredFinding.packHeading): each is a verified review finding whose "
        + "test waited on code your branch now holds; write that test in your write set",
      anchor: nil, lines: deferred.map(\.packLine))
  }

  /// The areas holding `writeSet`, in config order: each entry belongs to the area with the
  /// longest root that contains it.
  public static func areas(holding writeSet: [String], in areas: [BrownfieldArea])
    -> [BrownfieldArea]
  {
    var names: Set<String> = []
    for entry in writeSet {
      let owner =
        areas
        .filter { contains(root: $0.root, path: entry) }
        .max { rootDepth($0.root) < rootDepth($1.root) }
      if let owner { names.insert(owner.name) }
    }
    return areas.filter { names.contains($0.name) }
  }

  private static func contains(root: String, path: String) -> Bool {
    let root = trimmed(root)
    let path = trimmed(path)
    return root.isEmpty || path == root || path.hasPrefix(root + "/")
  }

  private static func rootDepth(_ root: String) -> Int {
    let root = trimmed(root)
    return root.isEmpty ? 0 : root.split(separator: "/").count
  }

  /// `.`, `./x` and `x/` as the plain repository-relative form, with `.` as the empty string.
  private static func trimmed(_ path: String) -> String {
    var path = Substring(path)
    while path.hasPrefix("./") { path = path.dropFirst(2) }
    if path == "." { return "" }
    while path.hasSuffix("/") { path = path.dropLast() }
    return String(path)
  }

  /// The area as `config.toml` spells its keys; a step with no command is named, so the worker
  /// knows no gate runs it.
  private static func areaLines(_ area: BrownfieldArea) -> [String] {
    var lines = [
      "name = \(area.name)", "root = \(area.root)", "language = \(area.language.rawValue)",
      "kind = \(area.kind.rawValue)",
    ]
    let steps: [(AreaStep, String?)] = [
      (.build, area.build), (.test, area.test), (.testFiles, area.testFiles), (.lint, area.lint),
      (.e2e, area.e2e),
    ]
    for (step, command) in steps {
      lines.append("\(step.rawValue) = \(command ?? "none: no gate runs this step")")
    }
    if !area.testGlobs.isEmpty {
      lines.append("test_globs = \(area.testGlobs.joined(separator: ", "))")
    }
    if let xcode = area.xcode {
      lines.append("xcode inclusion = \(xcode.inclusion.rawValue)")
    }
    return lines
  }

  /// The commands a worker runs itself in `area`: 1 test through `test-only`, and for a swiftpm
  /// area a build in the scratch path the clone's gates share, which the raw-swift-build guard
  /// passes. The area's own `build` and `test` are the gate's; run bare, they build cold.
  private static func workerCommandLines(_ area: BrownfieldArea, layout: BrownfieldStateLayout?)
    -> [String]
  {
    let testOnly = AcceptanceTestReference.testOnlyCommand(
      area: area.name, id: AcceptanceTestReference.filterSpelling(of: area.kind))
    var lines = ["run 1 test = \(testOnly)"]
    if area.kind == .swiftpm, let layout {
      let root = trimmed(area.root)
      let scratch = ScratchTreeBuild.swiftPMScratchPath(area: area.name, layout: layout)
      lines.append(
        "build only = swift build --package-path \(root.isEmpty ? "." : root) --scratch-path \(scratch)"
      )
    }
    return lines
  }

  private static func sections(_ sections: [MarkdownDocument.Section])
    -> [MarkdownDocument.Section]
  {
    sections.flatMap { [$0] + self.sections($0.subsections) }
  }
}

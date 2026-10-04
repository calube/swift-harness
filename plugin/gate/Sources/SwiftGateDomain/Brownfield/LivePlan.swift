import Foundation

/// The part of a task's plan section the run viewer's task drawer shows: the goal, why, scope,
/// acceptance and out-of-scope lines, as the plan's author wrote them.
public struct TaskBrief: Sendable, Equatable, Codable {
  /// The section's one-line goal.
  public let title: String
  /// `nil` when the section has no `- Why:` line.
  public let why: String?
  /// The first design section (`§…`) the why cites; `nil` when it cites none.
  public let designRef: String?
  public let scope: [String]
  public let acceptance: [String]
  public let outOfScope: [String]

  public init(
    title: String, why: String?, designRef: String?, scope: [String], acceptance: [String],
    outOfScope: [String]
  ) {
    self.title = title
    self.why = why
    self.designRef = designRef
    self.scope = scope
    self.acceptance = acceptance
    self.outOfScope = outOfScope
  }

  private enum CodingKeys: String, CodingKey {
    case title, why, designRef, scope, acceptance, outOfScope
  }

  /// `why` and `designRef` are omitted when `nil`, never written as an empty string.
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(title, forKey: .title)
    try c.encodeIfPresent(why, forKey: .why)
    try c.encodeIfPresent(designRef, forKey: .designRef)
    try c.encode(scope, forKey: .scope)
    try c.encode(acceptance, forKey: .acceptance)
    try c.encode(outOfScope, forKey: .outOfScope)
  }
}

/// One `### <task-id>` section of a brownfield `PLAN.md`.
public struct LivePlanTask: Sendable, Equatable {
  public let id: String
  public let deps: [String]
  public let gate: CheckTier
  /// `nil` when the section names no model; the preset's worker model applies.
  public let model: TaskModel?
  public let estLines: Int
  /// Exact paths or `/`-terminated prefixes, repo-relative.
  public let writes: [String]
  public let brief: TaskBrief
  /// The ids of `## Requirements` its `- Covers:` line names.
  public let covers: [String]

  public init(
    id: String, deps: [String], gate: CheckTier, model: TaskModel?, estLines: Int,
    writes: [String], brief: TaskBrief, covers: [String] = []
  ) {
    self.id = id
    self.deps = deps
    self.gate = gate
    self.model = model
    self.estLines = estLines
    self.writes = writes
    self.brief = brief
    self.covers = covers
  }
}

/// 1 bullet of a live plan's `## Requirements`: `- <id>: <title>`.
public struct LivePlanRequirement: Sendable, Equatable, Codable {
  public let id: String
  public let title: String

  public init(id: String, title: String) {
    self.id = id
    self.title = title
  }
}

/// A brownfield run's live plan, `<common>/swift-harness/plans/<slug>/PLAN.md`, as parsed.
public struct LivePlan: Sendable, Equatable {
  public let tasks: [LivePlanTask]
  /// One entry per bullet of the `## Assumptions` section: each reading made of an ambiguous spec.
  public let assumptions: [String]
  /// The `## Requirements` bullets, in plan order; empty when the plan has none.
  public let requirements: [LivePlanRequirement]
  /// The `## Validation` table; `nil` when the plan has no such section.
  public let validation: LivePlanValidation?

  public init(
    tasks: [LivePlanTask], assumptions: [String], requirements: [LivePlanRequirement] = [],
    validation: LivePlanValidation? = nil
  ) {
    self.tasks = tasks
    self.assumptions = assumptions
    self.requirements = requirements
    self.validation = validation
  }
}

/// Why a `PLAN.md` can't become a ledger. Each case names the task and the line at fault.
public enum LivePlanError: Error, Sendable, Equatable {
  case noTasks
  case duplicateTask(String)
  case missingGoal(task: String)
  case missingField(task: String, field: String)
  case unknownGate(task: String, value: String)
  /// A tier of the owned profile, which a brownfield clone can't run.
  case ownedProfileGate(task: String, tier: CheckTier)
  case unknownModel(task: String, value: String)
  case invalidEstLines(task: String, value: String)
  case noWrites(task: String)
  case invalidWrite(task: String, path: String)
  case missingDependency(task: String, dependency: String)
  case cycle(ids: [String])
  /// A `## Requirements` bullet that isn't `- <id>: <title>`.
  case invalidRequirement(line: String)
  case duplicateRequirement(String)
  /// A `- Covers:` id `## Requirements` doesn't list.
  case unknownRequirement(task: String, id: String)
  /// A requirement no task's `- Covers:` names.
  case uncoveredRequirement(String)
  /// A `## Validation` line that isn't a row of the table's shape.
  case invalidValidation(line: Int, reason: String)

  /// One sentence naming the task and what to fix in `PLAN.md`.
  public var message: String {
    switch self {
    case .noTasks:
      "PLAN.md has no task section: each task is a `### <task-id>` heading"
    case .duplicateTask(let id):
      "task `\(id)` has more than 1 section in PLAN.md"
    case .missingGoal(let task):
      "task `\(task)` has no one-line goal under its heading"
    case .missingField(let task, let field):
      "task `\(task)` has no `\(field)`"
    case .unknownGate(let task, let value):
      "task `\(task)` gates on `\(value)`, which is no tier; use slice, merge or final"
    case .ownedProfileGate(let task, let tier):
      "task `\(task)` gates on `\(tier.rawValue)`, a tier of the owned profile; a brownfield "
        + "clone runs slice, merge or final"
    case .unknownModel(let task, let value):
      "task `\(task)` names model `\(value)`; use "
        + TaskModel.allCases.map(\.rawValue).joined(separator: " or ")
    case .invalidEstLines(let task, let value):
      "task `\(task)` has estLines `\(value)`, which is not a whole number of lines"
    case .noWrites(let task):
      "task `\(task)` has no `- Writes:` paths, so its write set is unknown"
    case .invalidWrite(let task, let path):
      "task `\(task)` writes `\(path)`, which is not a path inside the repository"
    case .missingDependency(let task, let dependency):
      "task `\(task)` depends on `\(dependency)`, which has no section in PLAN.md"
    case .cycle(let ids):
      "the tasks' dependencies form a cycle: " + ids.joined(separator: " -> ")
    case .invalidRequirement(let line):
      "`## Requirements` line `\(line)` is not `- <id>: <title>`"
    case .duplicateRequirement(let id):
      "requirement `\(id)` is listed more than once under `## Requirements`"
    case .unknownRequirement(let task, let id):
      "task `\(task)` covers `\(id)`, which `## Requirements` doesn't list"
    case .uncoveredRequirement(let id):
      "requirement `\(id)` is in `## Requirements` but no task's `- Covers:` names it"
    case .invalidValidation(let line, let reason):
      "`## Validation` line \(line): \(reason)"
    }
  }
}

/// Reads `PLAN.md` in the task-section shape the brownfield plan fixes: a `### <task-id>`
/// heading, a one-line goal, `- Deps: … · Gate: … · Model: … · estLines: …`, then `- Why:`,
/// `- Scope:`, `- Acceptance:`, `- Out of scope:`, `- Covers:`, `- Writes:` and others. A list
/// value is the text after its colon, then each indented `- ` item under it. `## Requirements`
/// lists `- <id>: <title>`; each id needs a task that covers it, and a task covers listed ids only.
public enum LivePlanParser {
  private struct Section {
    let id: String
    var goal: String?
    /// Keyed by the lowercased field name; the inline value first, then indented items.
    var fields: [String: [String]] = [:]
    var lastField: String?
  }

  public static func parse(_ text: String) throws(LivePlanError) -> LivePlan {
    var sections: [Section] = []
    var current: Section?
    var inAssumptions = false
    var assumptions: [String] = []
    var inRequirements = false
    var requirementLines: [String] = []
    var inValidation = false
    var validationHeading: Int?
    var validationLines: [(line: Int, text: String)] = []

    func close() {
      if let current { sections.append(current) }
      current = nil
    }

    for (offset, raw) in text.split(
      omittingEmptySubsequences: false, whereSeparator: \.isNewline
    ).enumerated() {
      let line = String(raw)
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("## ") || line.hasPrefix("# ") {
        close()
        let heading =
          line.hasPrefix("## ")
          ? trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased() : ""
        inAssumptions = heading == "assumptions"
        inRequirements = heading == "requirements"
        inValidation = heading == "validation"
        if inValidation {
          if validationHeading != nil {
            throw .invalidValidation(line: offset + 1, reason: "a second `## Validation` section")
          }
          validationHeading = offset + 1
        }
        continue
      }
      if line.hasPrefix("### ") {
        close()
        inAssumptions = false
        inRequirements = false
        inValidation = false
        let id = stripTicks(String(trimmed.dropFirst(4)))
        if isTaskID(id) { current = Section(id: id) }
        continue
      }
      if inValidation {
        if trimmed.hasPrefix("|") { validationLines.append((offset + 1, trimmed)) }
        continue
      }
      if inRequirements {
        if line.hasPrefix("- ") {
          requirementLines.append(trimmed)
        } else if !trimmed.isEmpty, let last = requirementLines.popLast() {
          requirementLines.append(last + " " + trimmed)
        }
        continue
      }
      if inAssumptions {
        if line.hasPrefix("- ") {
          assumptions.append(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
        } else if !trimmed.isEmpty, let last = assumptions.popLast() {
          assumptions.append(last + " " + trimmed)
        }
        continue
      }
      guard var section = current, !trimmed.isEmpty else { continue }
      if line.hasPrefix("- ") {
        let body = String(line.dropFirst(2))
        if let colon = body.firstIndex(of: ":") {
          let key = body[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
          let value = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)
          section.fields[key] = value.isEmpty ? [] : [value]
          section.lastField = key
        } else {
          section.lastField = nil
        }
      } else if line.first?.isWhitespace == true, let key = section.lastField {
        if trimmed.hasPrefix("- ") {
          section.fields[key, default: []].append(
            String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces))
        } else if var values = section.fields[key], let last = values.popLast() {
          section.fields[key] = values + [last + " " + trimmed]
        }
      } else if section.goal == nil, section.fields.isEmpty {
        section.goal = trimmed
      }
      current = section
    }
    close()

    guard !sections.isEmpty else { throw .noTasks }
    var seen: Set<String> = []
    var tasks: [LivePlanTask] = []
    for section in sections {
      guard seen.insert(section.id).inserted else { throw .duplicateTask(section.id) }
      tasks.append(try task(section))
    }
    let requirements = try requirements(requirementLines)
    try checkCovers(tasks, requirements: requirements)
    let validation = try validationHeading.map { heading throws(LivePlanError) in
      try ValidationSection.parse(
        heading: heading, lines: validationLines, requirements: Set(requirements.map(\.id)))
    }
    return LivePlan(
      tasks: tasks, assumptions: assumptions, requirements: requirements, validation: validation)
  }

  /// Each `- <id>: <title>` bullet, the id in the task-id alphabet and optionally in backticks.
  private static func requirements(_ lines: [String]) throws(LivePlanError)
    -> [LivePlanRequirement]
  {
    var requirements: [LivePlanRequirement] = []
    var seen: Set<String> = []
    for line in lines {
      let body = line.dropFirst(2)
      guard let colon = body.firstIndex(of: ":") else { throw .invalidRequirement(line: line) }
      let id = stripTicks(String(body[..<colon]))
      let title = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      guard isTaskID(id), !title.isEmpty else { throw .invalidRequirement(line: line) }
      guard seen.insert(id).inserted else { throw .duplicateRequirement(id) }
      requirements.append(LivePlanRequirement(id: id, title: title))
    }
    return requirements
  }

  /// Every id a task covers is a listed requirement, and every requirement has a task.
  private static func checkCovers(
    _ tasks: [LivePlanTask], requirements: [LivePlanRequirement]
  ) throws(LivePlanError) {
    let known = Set(requirements.map(\.id))
    for task in tasks {
      for id in task.covers where !known.contains(id) {
        throw .unknownRequirement(task: task.id, id: id)
      }
    }
    let covered = Set(tasks.flatMap(\.covers))
    if let uncovered = requirements.first(where: { !covered.contains($0.id) }) {
      throw .uncoveredRequirement(uncovered.id)
    }
  }

  private static func task(_ section: Section) throws(LivePlanError) -> LivePlanTask {
    let id = section.id
    guard let goal = section.goal else { throw .missingGoal(task: id) }
    guard let header = section.fields["deps"]?.first else {
      throw .missingField(task: id, field: "- Deps: … · Gate: … · estLines: …")
    }
    // The header line is `Deps: a, b · Gate: slice · …`; the bullet parse already cut `Deps:`.
    var pairs: [String: String] = [:]
    let parts = header.components(separatedBy: "·").map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    pairs["deps"] = parts.first ?? ""
    for part in parts.dropFirst() {
      guard let colon = part.firstIndex(of: ":") else { continue }
      pairs[part[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
        part[part.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }

    let rawDeps = pairs["deps"] ?? ""
    let deps =
      rawDeps.lowercased() == "none"
      ? [] : list(rawDeps)

    guard let rawGate = pairs["gate"], !rawGate.isEmpty else {
      throw .missingField(task: id, field: "Gate")
    }
    guard let gate = CheckTier(rawValue: stripTicks(rawGate)) else {
      throw .unknownGate(task: id, value: rawGate)
    }
    guard gate.profile == .brownfield else { throw .ownedProfileGate(task: id, tier: gate) }

    var model: TaskModel?
    if let rawModel = pairs["model"] {
      guard let known = TaskModel(rawValue: stripTicks(rawModel)) else {
        throw .unknownModel(task: id, value: rawModel)
      }
      model = known
    }

    guard let rawLines = pairs["estlines"] else { throw .missingField(task: id, field: "estLines") }
    guard let estLines = Int(rawLines), estLines >= 0 else {
      throw .invalidEstLines(task: id, value: rawLines)
    }

    let writes = (section.fields["writes"] ?? []).flatMap(list)
    guard !writes.isEmpty else { throw .noWrites(task: id) }
    for path in writes where !isRepositoryPath(path) {
      throw .invalidWrite(task: id, path: path)
    }

    let why = section.fields["why"].map { $0.joined(separator: " ") }
    let brief = TaskBrief(
      title: goal, why: why, designRef: why.flatMap(designRef),
      scope: section.fields["scope"] ?? [],
      acceptance: section.fields["acceptance"] ?? [],
      outOfScope: section.fields["out of scope"] ?? [])
    return LivePlanTask(
      id: id, deps: deps, gate: gate, model: model, estLines: estLines, writes: writes,
      brief: brief, covers: (section.fields["covers"] ?? []).flatMap(list))
  }

  private static func list(_ text: String) -> [String] {
    text.split(separator: ",").map { stripTicks(String($0)) }.filter { !$0.isEmpty }
  }

  private static func stripTicks(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespaces).trimmingCharacters(
      in: CharacterSet(charactersIn: "`"))
  }

  private static func isTaskID(_ text: String) -> Bool {
    guard let first = text.unicodeScalars.first,
      CharacterSet.lowercaseLetters.contains(first)
        || CharacterSet.decimalDigits.contains(first)
    else { return false }
    return text.unicodeScalars.allSatisfy {
      ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-"
    }
  }

  private static func isRepositoryPath(_ path: String) -> Bool {
    guard !path.hasPrefix("/"), !path.contains(where: { $0.isWhitespace || $0 == "\0" }) else {
      return false
    }
    return path.split(separator: "/", omittingEmptySubsequences: true).allSatisfy {
      $0 != "." && $0 != ".."
    }
  }

  /// The first `§` reference in `text`, such as `§4.2`.
  private static func designRef(_ text: String) -> String? {
    guard let sign = text.firstIndex(of: "§") else { return nil }
    let rest = text[text.index(after: sign)...]
    var number = rest.prefix { $0.isNumber || $0 == "." }
    while number.hasSuffix(".") { number = number.dropLast() }
    return number.isEmpty ? nil : "§" + number
  }
}

/// Reads the `## Validation` table: a header naming `Done when`, `Layer`, `Check`, `Runs after`,
/// `Writer` and optionally `Reason`, a separator line, then 1 row per check. A row with an empty
/// `Layer` is a unit-only reason.
private enum ValidationSection {
  private enum Column: String, CaseIterable {
    case doneWhen = "Done when"
    case layer = "Layer"
    case check = "Check"
    case runsAfter = "Runs after"
    case writer = "Writer"
    case reason = "Reason"
  }

  static func parse(
    heading: Int, lines: [(line: Int, text: String)], requirements: Set<String>
  ) throws(LivePlanError) -> LivePlanValidation {
    guard let header = lines.first else {
      throw .invalidValidation(
        line: heading,
        reason: "the section has no table; give it 1 with a header and a separator line")
    }
    var columns: [Column] = []
    for name in cells(header.text) {
      guard
        let column = Column.allCases.first(where: {
          $0.rawValue.lowercased() == stripTicks(name).lowercased()
        })
      else {
        throw .invalidValidation(
          line: header.line,
          reason: "`\(name)` is not a column; use "
            + Column.allCases.map { "`\($0.rawValue)`" }.joined(separator: ", "))
      }
      columns.append(column)
    }
    for column in Column.allCases where column != .reason && !columns.contains(column) {
      throw .invalidValidation(
        line: header.line, reason: "the table's header has no `\(column.rawValue)` column")
    }
    guard lines.count > 1, isSeparator(lines[1].text) else {
      throw .invalidValidation(
        line: lines.count > 1 ? lines[1].line : header.line,
        reason: "the header isn't followed by a `|---|` separator line")
    }

    var rows: [ValidationRow] = []
    var rowLines: [Int] = []
    var unitOnly: [ValidationUnitOnly] = []
    for (line, text) in lines.dropFirst(2) {
      let values = cells(text)
      guard values.count == columns.count else {
        throw .invalidValidation(
          line: line,
          reason: "the row has \(values.count) cells and the header \(columns.count)")
      }
      var cell: [Column: String] = [:]
      for (column, value) in zip(columns, values) { cell[column] = value }
      func value(_ column: Column) -> String { stripTicks(cell[column] ?? "") }

      let requirement = value(.doneWhen)
      guard requirements.contains(requirement) else {
        throw .invalidValidation(
          line: line, reason: "`\(requirement)` is not a `## Requirements` id")
      }
      let reason = cell[.reason].flatMap { $0.isEmpty ? nil : $0 }
      let rawLayer = value(.layer)
      if rawLayer.isEmpty || rawLayer == "—" || rawLayer == "-" {
        for column in [Column.check, .runsAfter, .writer] where !value(column).isEmpty {
          throw .invalidValidation(
            line: line,
            reason: "the row has no `Layer`, so it is a unit-only reason and leaves "
              + "`\(column.rawValue)` empty")
        }
        guard let reason else {
          throw .invalidValidation(
            line: line,
            reason: "the row has no `Layer`, so it needs a `Reason` saying why the "
              + "requirement's unit tests suffice")
        }
        unitOnly.append(ValidationUnitOnly(requirement: requirement, reason: reason))
        continue
      }
      guard let layer = ValidationLayer(rawValue: rawLayer) else {
        throw .invalidValidation(
          line: line,
          reason: "layer `\(rawLayer)` is not a validation layer; use acceptance, flow or state, "
            + "or leave `Layer` empty and give a `Reason` when the requirement's unit tests suffice"
        )
      }
      let check = unwrap(cell[.check] ?? "")
      guard !check.isEmpty else {
        throw .invalidValidation(line: line, reason: "the row's `Check` is empty")
      }
      let runsAfter = (cell[.runsAfter] ?? "").split(separator: ",").map {
        stripTicks(String($0))
      }.filter { !$0.isEmpty }
      guard !runsAfter.isEmpty else {
        throw .invalidValidation(line: line, reason: "the row's `Runs after` is empty")
      }
      let writer = value(.writer)
      guard !writer.isEmpty else {
        throw .invalidValidation(line: line, reason: "the row's `Writer` is empty")
      }
      rows.append(
        ValidationRow(
          requirement: requirement, layer: layer, check: check, runsAfter: runsAfter,
          writer: writer, reason: reason))
      rowLines.append(line)
    }
    return LivePlanValidation(
      table: ValidationTable(rows: rows, unitOnly: unitOnly), headingLine: heading,
      rowLines: rowLines)
  }

  /// A row's cells, split on each `|` not escaped as `\|`, with `\|` read as `|`.
  private static func cells(_ row: String) -> [String] {
    var body = Substring(row.trimmingCharacters(in: .whitespaces))
    if body.hasPrefix("|") { body = body.dropFirst() }
    if body.hasSuffix("|"), !body.hasSuffix("\\|") { body = body.dropLast() }
    var cells: [String] = []
    var current = ""
    var escaped = false
    for character in body {
      if escaped {
        current.append(character == "|" ? "|" : "\\\(character)")
        escaped = false
      } else if character == "\\" {
        escaped = true
      } else if character == "|" {
        cells.append(current.trimmingCharacters(in: .whitespaces))
        current = ""
      } else {
        current.append(character)
      }
    }
    if escaped { current.append("\\") }
    cells.append(current.trimmingCharacters(in: .whitespaces))
    return cells
  }

  private static func isSeparator(_ row: String) -> Bool {
    let values = cells(row)
    return !values.isEmpty
      && values.allSatisfy { value in
        let dashes = value.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        return !dashes.isEmpty && dashes.allSatisfy { $0 == "-" }
      }
  }

  /// The first code span's text when the cell opens with one, so a check written as
  /// `` `cmd`: what it reads `` runs `cmd`; otherwise the whole cell.
  private static func unwrap(_ cell: String) -> String {
    guard cell.hasPrefix("`") else { return cell }
    let rest = cell.dropFirst()
    guard let close = rest.firstIndex(of: "`") else { return stripTicks(cell) }
    return rest[..<close].trimmingCharacters(in: .whitespaces)
  }

  private static func stripTicks(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespaces).trimmingCharacters(
      in: CharacterSet(charactersIn: "`"))
  }
}

extension LivePlan {
  /// The executor's ledger. A task id `existing` already holds keeps its status, branch, worktree
  /// and line count, so a re-import after an edit doesn't reset work in flight.
  public func ledger(
    maxParallel: Int, existing: Ledger?, worktree: (String) -> String
  ) throws(LivePlanError) -> Ledger {
    let kept = Dictionary(
      (existing?.tasks ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let ledgerTasks = tasks.map { task in
      let old = kept[task.id]
      return LedgerTask(
        id: task.id, deps: task.deps, writeSet: task.writes, gate: task.gate, tests: [],
        covers: task.covers, estLines: task.estLines, status: old?.status ?? .pending,
        worktree: old?.worktree ?? worktree(task.id), actualLines: old?.actualLines,
        model: task.model, branch: old?.branch)
    }
    let waves: [[String]]
    switch PlanSchedule.schedule(tasks: ledgerTasks, maxParallel: maxParallel) {
    case .success(let scheduled): waves = scheduled
    case .failure(.missingDependency(let task, let dependency)):
      throw .missingDependency(task: task, dependency: dependency)
    case .failure(.cycle(let ids)): throw .cycle(ids: ids)
    case .failure(.duplicateTaskID(let ids)): throw .duplicateTask(ids.first ?? "")
    }
    let resume =
      "planned; \(tasks.count) tasks in \(waves.count) waves; next: build the first wave"
    return Ledger(
      schemaVersion: 1, resume: resume, maxParallel: maxParallel, tasks: ledgerTasks,
      waves: waves)
  }

  /// A live-plan `plan.json` carrying each task's brief. `existing`'s surface commit is kept.
  public func planFile(slug: String, resume: String, existing: PlanFile?) -> PlanFile {
    PlanFile(
      schemaVersion: 1, slug: slug,
      source: .livePlan(
        PlanFile.LivePlanSource(
          briefs: Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.brief) }),
          requirements: requirements)),
      surfaceCommit: existing?.surfaceCommit, resume: resume)
  }
}

/// The `.git/info/exclude` line that keeps the root `PLAN.md` symlink out of `git status`.
public enum LivePlanExclude {
  public static let line = "/" + PlanFile.LivePlanSource.fileName

  /// `text` with ``line`` appended, or `nil` when it already holds the line.
  public static func adding(to text: String?) -> String? {
    let existing = text ?? ""
    let lines = existing.split(whereSeparator: \.isNewline).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    guard !lines.contains(line) else { return nil }
    let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
    return existing + separator + line + "\n"
  }
}

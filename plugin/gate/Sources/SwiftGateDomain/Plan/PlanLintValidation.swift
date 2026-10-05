/// `plan-lint`'s checks of a plan's validation table (simulator QA amendment §4.3). Pure: the
/// table, the requirement ids and the task ids arrive already read.
public enum PlanLintValidation {
  public static let uncoveredRuleID = "plan-lint.validation-uncovered"
  public static let unknownTaskRuleID = "plan-lint.validation-unknown-task"
  public static let stateWithoutFlowRuleID = "plan-lint.validation-state-without-flow"
  public static let flowWithoutIOSRuleID = "plan-lint.validation-flow-without-ios"
  public static let checkSourceFileRuleID = "plan-lint.validation-check-source-file"
  public static let screenWithoutFlowRuleID = "plan-lint.validation-screen-without-flow"
  public static let appWithoutFlowRuleID = "plan-lint.validation-app-without-flow"
  public static let obstacleFakeableRuleID = "plan-lint.validation-obstacle-fakeable"

  /// What may stop a flow checking a screen requirement. A screen requirement's `Reason` opens
  /// with 1 of these and a colon, such as `data: needs a source with 50 chapters`, or it doesn't
  /// excuse the requirement from a flow row: unit and acceptance tests never stand in for one.
  public static let obstacleKinds = ["network", "hardware", "account", "data", "system"]

  /// The obstacle kind `reason` opens with, when a detail follows its colon; `nil` otherwise.
  public static func obstacle(of reason: String) -> String? {
    let text = reason.trimmingCharacters(in: .whitespaces)
    guard let colon = text.firstIndex(of: ":") else { return nil }
    let kind = String(text[..<colon])
    guard obstacleKinds.contains(kind),
      !text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces).isEmpty
    else { return nil }
    return kind
  }

  /// The tag of a reason-only row whose requirement the gates' own suites prove, such as
  /// `gate: final runs every area's whole suite`. It excuses a requirement about the
  /// repository's existing tests from a flow row, and nothing else.
  public static let gateReasonKind = "gate"

  /// The gate tiers a ``gateReasonKind`` reason names as running the whole suites.
  public static let suiteTiers = ["merge", "final"]

  /// Whether `reason` opens with `gate:` and names a tier of ``suiteTiers`` after it.
  public static func isGateReason(_ reason: String) -> Bool {
    let text = reason.trimmingCharacters(in: .whitespaces)
    guard text.hasPrefix(gateReasonKind + ":") else { return false }
    return words(text.dropFirst(gateReasonKind.count + 1)).contains { suiteTiers.contains($0) }
  }

  /// Whether a requirement's title is about the repository's tests, such as "the existing tests
  /// keep passing".
  public static func namesTests(_ title: String) -> Bool {
    words(title).contains { ["test", "tests", "suite", "suites"].contains($0) }
  }

  /// The lowercased runs of letters in `text`.
  private static func words(_ text: some StringProtocol) -> [String] {
    text.lowercased().split { !$0.isLetter }.map(String.init)
  }

  /// Obstacle kinds a dependency client's fake removes: with a client module in the app's area, a
  /// fake chosen at launch serves the failure, the retry or the slow response the flow needs.
  public static let fakeableObstacleKinds = ["network"]

  /// The dependency-client modules among `paths`, repository-relative files: each outermost
  /// folder named `…Client` that holds a Swift file, such as `Packages/APIClient`, in path order.
  public static func clientModules(in paths: [String]) -> [String] {
    var modules: [String] = []
    for path in paths where path.hasSuffix(".swift") {
      let folders = path.split(separator: "/").dropLast()
      guard let index = folders.firstIndex(where: { $0.hasSuffix("Client") }) else { continue }
      let module = folders[...index].joined(separator: "/")
      if !modules.contains(module) { modules.append(module) }
    }
    return modules
  }

  /// A task as the screen check reads it: the requirements it covers and the paths it writes.
  public struct TaskWrites: Sendable, Equatable {
    public let id: String
    public let covers: [String]
    /// Repository-relative paths; a path ending in `/` is a prefix.
    public let writes: [String]

    public init(id: String, covers: [String], writes: [String]) {
      self.id = id
      self.covers = covers
      self.writes = writes
    }
  }

  /// An `xcode` area: an app whose screens a flow row can drive.
  public struct AppArea: Sendable, Equatable {
    public let name: String
    /// Repository-relative; `.` is the repository root.
    public let root: String

    public init(name: String, root: String) {
      self.name = name
      self.root = root
    }
  }

  /// Every finding, each `major`: uncovered requirements in plan order, then each row's findings
  /// in table order, then the screen requirements with no flow row in plan order, then the app
  /// areas with no flow row in area order.
  ///
  /// - Parameters:
  ///   - requirements: the plan's requirement ids, in plan order.
  ///   - taskIDs: every ledger task id.
  ///   - hasIOSArea: whether the repository has an app a flow can drive.
  ///   - file: the file findings name: `PLAN.md` or `validation.json`.
  ///   - rowLines: the line of each of `table.rows`, when the table came from markdown.
  ///   - sectionLine: the line the table starts on, when it came from markdown.
  ///   - tasks: each task's covers and writes, for the screen check; empty skips it.
  ///   - appAreas: the repository's `xcode` areas, whose screens a task can touch.
  ///   - contractTask: the contract task, whose stub screens carry no behaviour a flow can check.
  ///   - clientModules: the repository's dependency-client modules, from ``clientModules(in:)``;
  ///     1 inside an app's area stops a ``fakeableObstacleKinds`` reason excusing its screens.
  ///   - requirementTitles: each requirement's title by id, which says whether a
  ///     ``gateReasonKind`` reason may excuse it.
  public static func findings(
    table: ValidationTable, requirements: [String], taskIDs: Set<String>, hasIOSArea: Bool,
    file: String, rowLines: [Int] = [], sectionLine: Int? = nil, tasks: [TaskWrites] = [],
    appAreas: [AppArea] = [], contractTask: String? = nil, clientModules: [String] = [],
    requirementTitles: [String: String] = [:]
  ) throws(ReportContractViolation) -> [Finding] {
    var findings: [Finding] = []
    let checked = Set(table.rows.map(\.requirement) + table.unitOnly.map(\.requirement))
    for requirement in requirements where !checked.contains(requirement) {
      findings.append(
        try Finding(
          ruleID: uncoveredRuleID, severity: .major, file: file, line: sectionLine,
          message:
            "\(requirement) has no validation row and no unit-only reason: give it an "
            + "acceptance, flow or state check, or a row whose Reason says its unit tests suffice",
          failureScenario:
            "every task covering \(requirement) merges green, and nothing checks it end to end"))
    }

    for (index, row) in table.rows.enumerated() {
      let line = index < rowLines.count ? rowLines[index] : nil
      let place = "\(row.requirement)'s \(row.layer.rawValue) row"
      for id in row.runsAfter where !taskIDs.contains(id) {
        findings.append(
          try Finding(
            ruleID: unknownTaskRuleID, severity: .major, file: file, line: line,
            message: "\(place) runs after `\(id)`, which is no task in the plan",
            failureScenario: "`\(id)` never merges, so the row waits for ever and never runs"))
      }
      if !taskIDs.contains(row.writer) {
        findings.append(
          try Finding(
            ruleID: unknownTaskRuleID, severity: .major, file: file, line: line,
            message: "\(place) is written by `\(row.writer)`, which is no task in the plan",
            failureScenario: "no worker is told to write `\(row.check)`, so the row has no check"))
      }
      if row.layer == .flow, !hasIOSArea {
        findings.append(
          try Finding(
            ruleID: flowWithoutIOSRuleID, severity: .major, file: file, line: line,
            message:
              "\(place) drives an app, but the repository has no Xcode area; check the "
              + "boundary with an acceptance row instead",
            failureScenario: "the flow has no app to launch, so the row can never pass"))
      }
      if row.layer == .acceptance, namesSourceFile(row.check) {
        let form =
          hasIOSArea
          ? "`test: <Target>/<Class>/<method>`, which runs the area's test command with "
            + "`-only-testing:`"
          : "`test: <selector>`, which the area's test_files places in `{tests}` or `{files}`"
        findings.append(
          try Finding(
            ruleID: checkSourceFileRuleID, severity: .major, file: file, line: line,
            message:
              "\(place) checks `\(row.check)`, a test source file that `qa run` would run as a "
              + "shell command; name the test as \(form), or give the runner's command",
            failureScenario:
              "/bin/sh can't execute a source file, so the row reads red on exit 126 or 127 "
              + "whatever the code does"))
      }
      if row.layer == .state, !hasPrecedingRow(row, in: table.rows, hasIOSArea: hasIOSArea) {
        let expected = hasIOSArea ? "a flow row" : "a flow or acceptance row"
        findings.append(
          try Finding(
            ruleID: stateWithoutFlowRuleID, severity: .major, file: file, line: line,
            message:
              "\(place) has no \(expected) for the same requirement that runs after the same "
              + "tasks (\(row.runsAfter.joined(separator: ", ")))",
            failureScenario:
              "the state script reads a result nothing in the run produced, so it passes or "
              + "fails on leftovers"))
      }
    }
    let screenTasks = tasks.filter { $0.id != contractTask }
    findings += try screenFindings(
      table: table, requirements: requirements, tasks: screenTasks, appAreas: appAreas,
      clientModules: clientModules, file: file, rowLines: rowLines, sectionLine: sectionLine,
      titles: requirementTitles)
    findings += try appFindings(
      table: table, screenTasks: screenTasks, allTasks: tasks, appAreas: appAreas, file: file,
      sectionLine: sectionLine)
    return findings
  }

  /// The app-without-flow findings alone, for a plan with no `## Validation` section (`table`
  /// `nil`), which then has no flow row for any app whose screens its tasks write.
  public static func appWithoutFlowFindings(
    table: ValidationTable?, tasks: [TaskWrites], appAreas: [AppArea], file: String,
    contractTask: String? = nil
  ) throws(ReportContractViolation) -> [Finding] {
    try appFindings(
      table: table, screenTasks: tasks.filter { $0.id != contractTask }, allTasks: tasks,
      appAreas: appAreas, file: file, sectionLine: nil)
  }

  /// 1 finding per requirement, in plan order, that a task covers while writing a screen or a
  /// feature of an `xcode` area, with no `flow` row and no reason on any of its rows naming an
  /// obstacle. A ``fakeableObstacleKinds`` obstacle counts only while no client module sits in
  /// that area; past it the finding is ``obstacleFakeableRuleID``. A requirement with no row but a
  /// reason-only one, whose title names tests and whose reason is a ``gateReasonKind`` naming a
  /// tier of ``suiteTiers``, is the gates' own to prove and has no finding.
  private static func screenFindings(
    table: ValidationTable, requirements: [String], tasks: [TaskWrites], appAreas: [AppArea],
    clientModules: [String], file: String, rowLines: [Int], sectionLine: Int?,
    titles: [String: String]
  ) throws(ReportContractViolation) -> [Finding] {
    guard !appAreas.isEmpty else { return [] }
    var findings: [Finding] = []
    for requirement in requirements {
      let rows = table.rows.enumerated().filter { $0.element.requirement == requirement }
      guard !rows.contains(where: { $0.element.layer == .flow }) else { continue }
      let reasons =
        (table.unitOnly.filter { $0.requirement == requirement }.map(\.reason)
        + rows.compactMap(\.element.reason)).filter {
          !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
      guard
        let (task, path, area) = tasks.lazy.filter({ $0.covers.contains(requirement) })
          .compactMap({ task in
            onScreenPath(task, appAreas).map { (task.id, $0.path, $0.area) }
          })
          .first
      else { continue }
      let gateReasons = table.unitOnly.filter { $0.requirement == requirement }.map(\.reason)
        .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix(gateReasonKind + ":") }
      let testsRequirement = titles[requirement].map(namesTests) ?? false
      if rows.isEmpty, testsRequirement, gateReasons.contains(where: isGateReason) { continue }
      let kinds = reasons.compactMap(obstacle(of:))
      let clients = clientModules.filter { contains(area.root, $0) }
      guard !kinds.contains(where: { clients.isEmpty || !fakeableObstacleKinds.contains($0) })
      else { continue }
      let line = rows.first.flatMap { $0.offset < rowLines.count ? rowLines[$0.offset] : nil }
      let onScreen =
        "\(requirement) is on screen: `\(task)` writes `\(path)` in the xcode area "
        + "`\(area.name)`"
      if let kind = kinds.first, let client = clients.first {
        findings.append(
          try Finding(
            ruleID: obstacleFakeableRuleID, severity: .major, file: file,
            line: line ?? sectionLine,
            message:
              "\(onScreen), and its Reason excuses it with `\(kind):`, but the area holds the "
              + "dependency client `\(client)`: a fake of it, chosen by a launch argument, serves "
              + "the failure or the data the journey needs; add a flow row that opens the app "
              + "with that fake, and a task or the contract that adds the fake",
            failureScenario:
              "the journey merges with no flow, so its error, retry or refresh path never runs "
              + "in the app, and the flows that do run hit the live service"))
        continue
      }
      let obstacles = obstacleKinds.map { "`\($0):`" }.joined(separator: ", ")
      let tiers = suiteTiers.map { "`\($0)`" }.joined(separator: " or ")
      let gate = "`\(gateReasonKind):`"
      let fix =
        !gateReasons.isEmpty && !testsRequirement
        ? "\(gate) excuses only a requirement whose title is about the repository's existing "
          + "tests, which the gates' own suites prove; add a flow row for its journey, or open "
          + "the Reason with what stops a flow: " + obstacles
        : !gateReasons.isEmpty
          ? "a \(gate) Reason excuses it only on its 1 reason-only row and naming the tier "
            + "that runs the whole suites, \(tiers), such as `\(gateReasonKind): final runs "
            + "every area's whole suite`"
        : reasons.isEmpty
        ? "add a flow row for its journey, or open its row's Reason with what stops a flow: "
          + obstacles
        : "its Reason names no obstacle a flow can't pass, and unit or acceptance tests never "
          + "stand in for a flow; add a flow row for its journey, or open the Reason with what "
          + "stops a flow: " + obstacles
      findings.append(
        try Finding(
          ruleID: screenWithoutFlowRuleID, severity: .major, file: file,
          line: line ?? sectionLine,
          message: "\(onScreen), but \(requirement) has no flow row; \(fix)",
          failureScenario:
            "the screen merges with no flow, so no video is recorded, nothing runs red at the "
            + "base, and the Validation tab has no journey for \(requirement)"))
    }
    return findings
  }

  /// 1 finding per `xcode` area, in area order, whose screens a task writes while no `flow` row
  /// runs after or covers the work of a task writing inside it. Reasons excuse single
  /// requirements, never a whole app.
  private static func appFindings(
    table: ValidationTable?, screenTasks: [TaskWrites], allTasks: [TaskWrites],
    appAreas: [AppArea], file: String, sectionLine: Int?
  ) throws(ReportContractViolation) -> [Finding] {
    var findings: [Finding] = []
    for area in appAreas {
      guard
        let (task, path) = screenTasks.lazy.compactMap({ task in
          screenPath(task, [area]).map { (task.id, $0.path) }
        }).first
      else { continue }
      let flowed = (table?.rows ?? []).contains { row in
        row.layer == .flow
          && allTasks.contains { task in
            (row.runsAfter.contains(task.id) || task.covers.contains(row.requirement))
              && task.writes.contains { contains(area.root, $0) }
          }
      }
      guard !flowed else { continue }
      findings.append(
        try Finding(
          ruleID: appWithoutFlowRuleID, severity: .major, file: file, line: sectionLine,
          message:
            "the xcode area `\(area.name)` gets screens (`\(task)` writes `\(path)`), but no "
            + "flow row drives it"
            + (table == nil ? " and the plan has no `## Validation` section" : "")
            + "; add at least 1 flow row for a journey through them: a Reason excuses 1 "
            + "requirement, never the whole app",
          failureScenario:
            "the app merges with no flow run, so no video is recorded, nothing runs red at the "
            + "base, and the Validation tab is empty"))
    }
    return findings
  }

  /// The first path `task` writes that is a screen inside 1 of `appAreas`, with that area's name.
  private static func screenPath(_ task: TaskWrites, _ appAreas: [AppArea])
    -> (path: String, area: String)?
  {
    for path in task.writes where isScreen(path) {
      if let area = appAreas.first(where: { contains($0.root, path) }) {
        return (path, area.name)
      }
    }
    return nil
  }

  /// The first path `task` writes that is a screen or a feature inside 1 of `appAreas`, with
  /// that area.
  private static func onScreenPath(_ task: TaskWrites, _ appAreas: [AppArea])
    -> (path: String, area: AppArea)?
  {
    for path in task.writes where isScreen(path) || isFeature(path) {
      if let area = appAreas.first(where: { contains($0.root, path) }) {
        return (path, area)
      }
    }
    return nil
  }

  /// Name endings that mark a feature: the reducer or view model whose state a screen shows.
  private static let featureSuffixes = [
    "Feature", "Features", "Reducer", "Reducers", "ViewModel", "ViewModels",
  ]

  /// Whether a folder or file of `path` names a feature, by its name up to the first `.`. Inside
  /// a `Sources` or `Tests` folder only the module and the files under it count, so a pure
  /// engine module in a feature package, or its tests, is no feature; nor is a package manifest.
  private static func isFeature(_ path: String) -> Bool {
    let components = path.split(separator: "/")
    guard let name = components.last, !name.hasPrefix("Package.") else { return false }
    let start = components.lastIndex { $0 == "Sources" || $0 == "Tests" }.map { $0 + 1 } ?? 0
    return components[start...].contains { component in
      guard let stem = component.split(separator: ".", maxSplits: 1).first else { return false }
      return featureSuffixes.contains { stem.hasSuffix($0) }
    }
  }

  /// Whether `root`, repository-relative with `.` for the root, holds `path`.
  private static func contains(_ root: String, _ path: String) -> Bool {
    var prefix = root
    while prefix.hasPrefix("./") { prefix.removeFirst(2) }
    while prefix.hasSuffix("/") { prefix.removeLast() }
    guard !prefix.isEmpty, prefix != "." else { return true }
    return path == prefix || path.hasPrefix(prefix + "/")
  }

  /// Name endings that mark a screen: SwiftUI and UIKit views, screens, UI modules and UI tests.
  private static let screenSuffixes = [
    "View", "Views", "Screen", "Screens", "ViewController", "UI", "UITests",
  ]
  private static let screenExtensions: Set<String> = ["storyboard", "xib"]

  /// Whether a folder or file of `path` names a screen, by its name up to the first `.`.
  private static func isScreen(_ path: String) -> Bool {
    path.split(separator: "/").contains { component in
      let parts = component.split(separator: ".", maxSplits: 1)
      if parts.count == 2, let ext = component.split(separator: ".").last,
        screenExtensions.contains(ext.lowercased())
      {
        return true
      }
      guard let stem = parts.first else { return false }
      return screenSuffixes.contains { stem.hasSuffix($0) }
        || ["ui", "views", "screens"].contains(stem.lowercased())
    }
  }

  /// Extensions of the source files test frameworks read; a check naming 1 is never a command.
  private static let sourceExtensions: Set<String> = [
    "swift", "m", "mm", "c", "cc", "cpp", "h", "kt", "kts", "java", "scala", "groovy", "go", "rs",
    "py", "rb", "js", "jsx", "mjs", "cjs", "ts", "tsx", "cs",
  ]

  /// Whether `check` is 1 word naming a source file: no runner, no `test:` reference, and not a
  /// `qa/` script the validation task writes.
  private static func namesSourceFile(_ check: String) -> Bool {
    let word = check.trimmingCharacters(in: .whitespaces)
    guard !word.isEmpty, !word.contains(where: \.isWhitespace), !word.hasPrefix("qa/"),
      AcceptanceTestReference.parse(word) == nil,
      let name = word.split(separator: "/").last, let dot = name.lastIndex(of: "."),
      dot != name.startIndex
    else { return false }
    return sourceExtensions.contains(name[name.index(after: dot)...].lowercased())
  }

  /// Whether a flow row, or where no app exists an acceptance row, produces what `state` reads:
  /// the same requirement, after the same tasks.
  private static func hasPrecedingRow(
    _ state: ValidationRow, in rows: [ValidationRow], hasIOSArea: Bool
  ) -> Bool {
    let tasks = Set(state.runsAfter)
    return rows.contains { row in
      let producer = row.layer == .flow || (!hasIOSArea && row.layer == .acceptance)
      return producer && row.requirement == state.requirement && Set(row.runsAfter) == tasks
    }
  }
}

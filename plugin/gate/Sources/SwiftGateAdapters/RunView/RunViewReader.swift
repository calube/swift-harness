import Darwin
import Foundation
import SwiftGateDomain

/// Reads the main store, each live task worktree's store and every imported store, the build join
/// and the plan, filtered to 1 build run.
///
/// An event belongs to the run when its payload names the run (`build.halt`, `build.resume`,
/// `build.return-checked`, `agent.usage`, `agent.tools`, `span.*`), or when it is a gate event (`gate.run`, `gate.step`,
/// `test.result`, `prove.result`) of a gate run the run's ledger log or a task return names.
///
/// A brownfield run has phases before its build run exists, so the plan's first build run also
/// keeps the spans that name the plan slug, and the `discover.run` and `warmup.run` events from
/// the plan's launch on, until another plan launches. No other event is kept.
public struct RunViewReader: RunViewReading {
  /// The git common dir, absolute.
  public let commonDirectory: URL
  /// Where this checkout's harness state lives.
  public let stateRoot: StateRoot
  /// Which ``TaskWorktree`` layout names the task worktrees and the checkout merges land in.
  public let profile: RepositoryProfile

  public init(
    commonDirectory: URL, stateRoot: StateRoot, profile: RepositoryProfile = .owned
  ) {
    self.commonDirectory = commonDirectory
    self.stateRoot = stateRoot
    self.profile = profile
  }

  public func read(buildRun: String) throws -> RunViewInput {
    var damage: [RunView.Damage] = []
    let joined = BuildJoinReader(commonDirectory: commonDirectory).read(buildRunID: buildRun)
    damage += joined.damage.map { RunView.Damage(source: $0.path, reason: $0.reason) }
    let join = joined.runs.first

    var ledger: Ledger?
    var requirements: [RunViewRequirement] = []
    var briefs: [String: RunView.Brief] = [:]
    var prebuild = Prebuild()
    if let join {
      let plan = try planState(join.plan, damage: &damage)
      ledger = plan.ledger
      requirements = plan.requirements
      briefs = plan.briefs
      prebuild = try self.prebuild(plan: join.plan, buildRun: buildRun, damage: &damage)
    }

    var batches: [[StoredEvent]] = []
    let main = EventStoreReader(files: StateRootEventFiles(state: stateRoot)).read(EventQuery())
    batches.append(main.events)
    damage += main.damage.map { Self.damage($0, in: nil) }
    // The main checkout's own files, without the worktree stores copied into it; their damage
    // is already counted above.
    let mainOwn = Set(
      EventStoreReader(files: StateRootEventFiles(state: stateRoot, includeCopies: false))
        .read(EventQuery()).events.map(\.event.eventID))
    // Every worktree of a brownfield clone writes to the main store, so a worker's gate runs are
    // among its own events there.
    var workerEvents = main.events.map(\.event).filter {
      profile == .brownfield || !mainOwn.contains($0.eventID)
    }
    var worktrees: [URL] = []
    var holders: [String: String] = [:]
    if let join, let ledger {
      worktrees = liveWorktrees(plan: join.plan, ledger: ledger, damage: &damage)
      holders = runHolders(plan: join.plan, ledger: ledger)
      for worktree in worktrees {
        let read = EventStoreReader(
          files: StateRootEventFiles(state: StateRootResolver.resolve(worktree: worktree))
        ).read(EventQuery())
        batches.append(read.events)
        workerEvents += read.events.map(\.event)
        damage += read.damage.map { Self.damage($0, in: worktree.lastPathComponent) }
      }
    }

    var gateRuns = join.map(Self.gateRuns(of:)) ?? []
    let workerGateRuns =
      join.map {
        Self.workerGateRuns(workerEvents, events: $0.events, named: gateRuns, holders: holders)
      } ?? [:]
    gateRuns.formUnion(workerGateRuns.keys)
    let events = EventQuery.merge(batches).map(\.event)
    let parents = Parents(events, buildRun: buildRun, gateRuns: gateRuns, prebuild: prebuild)
    let kept = events.filter {
      Self.belongs(
        $0, buildRun: buildRun, gateRuns: gateRuns, parents: parents, prebuild: prebuild)
    }
    let checkouts =
      [(stateRoot, nil as URL?)]
      + worktrees.map {
        (StateRootResolver.resolve(worktree: $0), $0)
      }
    let reports = gateReports(of: kept, in: checkouts, damage: &damage)
    return RunViewInput(
      buildRun: buildRun, events: kept, join: join, ledger: ledger, requirements: requirements,
      damage: damage, briefs: briefs, workerGateRuns: workerGateRuns,
      launchedAt: prebuild.launchedAt, gateReports: reports,
      checkoutRoots: checkoutRoots(worktrees: worktrees))
  }

  /// The `report.json` of each kept gate run that wasn't GREEN, from the first checkout whose
  /// state holds it: the main checkout's, then each live task worktree's. A report that exists
  /// and doesn't read is damage. One no checkout holds, as in a removed worktree, is absent, and
  /// the run's failure says so through its `nil` report.
  private func gateReports(
    of events: [HarnessEvent], in checkouts: [(state: StateRoot, worktree: URL?)],
    damage: inout [RunView.Damage]
  ) -> [String: RunViewGateReport] {
    var reports: [String: RunViewGateReport] = [:]
    for event in events {
      guard case .gateRun(let run) = event.payload, run.verdict != .green,
        let runID = event.runID, RunID.isValid(runID), reports[runID] == nil
      else { continue }
      let path = RunLayout.runDirectory(for: runID) + RunLayout.reportFileName
      for checkout in checkouts {
        let url = checkout.state.url(path)
        guard FileManager.default.fileExists(atPath: url.path) else { continue }
        let location = Self.location(path, in: checkout.state, worktree: checkout.worktree)
        // A read error names the file's absolute path, which the view must not carry.
        guard let data = try? Data(contentsOf: url) else {
          damage.append(RunView.Damage(source: location, reason: "unreadable"))
          break
        }
        do {
          let report = try RecordedRunReport.decode(data).report
          reports[runID] = RunViewGateReport(report: report, location: location)
        } catch {
          damage.append(RunView.Damage(source: location, reason: "not a gate report: \(error)"))
        }
        break
      }
    }
    return reports
  }

  /// `path` under `state`, named relative to the main checkout: a task worktree sits beside it.
  /// A state root under a git dir is named from that git dir, which has no relative name.
  static func location(_ path: String, in state: StateRoot, worktree: URL?) -> String {
    switch state {
    case .tree:
      let inTree = RunLayout.treePath(path)
      return worktree.map { "../\($0.lastPathComponent)/\(inTree)" } ?? inTree
    case .gitDir:
      let name = worktree.map { " of \($0.lastPathComponent)" } ?? ""
      return "<git dir\(name)>/\(RunLayout.gitDirDirectory)/\(path)"
    }
  }

  /// The main checkout and each live task worktree, each as written and with its links resolved.
  private func checkoutRoots(worktrees: [URL]) -> [String] {
    var roots: [URL] = worktrees
    switch stateRoot {
    case .tree(let checkout): roots.append(checkout)
    case .gitDir:
      if let checkout = try? TaskWorktree.mainCheckout(commonDirectory: commonDirectory.path) {
        roots.append(URL(filePath: checkout, directoryHint: .isDirectory))
      }
    }
    var paths: [String] = []
    for root in roots {
      for path in [root.standardizedFileURL.path, root.resolvingSymlinksInPath().path]
      where !paths.contains(path) {
        paths.append(path)
      }
    }
    return paths
  }

  /// What a build run keeps from before it existed. Empty for any build run but its plan's first.
  struct Prebuild: Equatable {
    /// The plan slug the run skill's phases before `build start` name as their build run.
    var slug: String?
    /// When `swiftgate run` launched the plan; `nil` when no `swiftgate run` did.
    var launchedAt: Date?
    /// When the next plan in this clone launched, which ends this plan's discovery and warm-up.
    var nextLaunch: Date?

    /// Whether a `discover.run` or `warmup.run` at `time` belongs to this plan's launch.
    func holds(_ time: Date) -> Bool {
      guard let launchedAt, time >= launchedAt else { return false }
      return nextLaunch.map { time < $0 } ?? true
    }
  }

  /// The plan's launch clock, when `buildRun` is the plan's first build run. A clock that
  /// doesn't read is damage, and the run then keeps only the spans that name the slug.
  private func prebuild(plan: String, buildRun: String, damage: inout [RunView.Damage]) throws
    -> Prebuild
  {
    let layout = try PlanStateLayout(commonDirectory: commonDirectory.path)
    let directory = try layout.plan(plan).directory
    let runs = (try? FileManager.default.contentsOfDirectory(atPath: directory + "/build")) ?? []
    guard runs.filter(RunID.isValid).min() == buildRun else { return Prebuild() }
    var prebuild = Prebuild(slug: plan)
    guard let launched = clock(directory, damage: &damage) else { return prebuild }
    prebuild.launchedAt = launched
    let plans = (try? FileManager.default.contentsOfDirectory(atPath: layout.root)) ?? []
    var ignored: [RunView.Damage] = []
    prebuild.nextLaunch =
      plans.filter { $0 != plan && $0 != PlanStateLayout.sprintsDirectoryName }
      .compactMap { other in
        (try? layout.plan(other).directory).flatMap { clock($0, damage: &ignored) }
      }
      .filter { $0 > launched }.min()
    return prebuild
  }

  /// `<plan dir>/clock.json`'s start; `nil` when the plan has none, as no owned plan does.
  private func clock(_ planDirectory: String, damage: inout [RunView.Damage]) -> Date? {
    let path = planDirectory + "/" + RunClock.fileName
    guard FileManager.default.fileExists(atPath: path),
      let data = read(path, damage: &damage)
    else { return nil }
    do {
      return try RunClock.decode(data).started
    } catch {
      damage.append(RunView.Damage(source: display(path), reason: "\(error)"))
      return nil
    }
  }

  /// The newest build run of any plan; `nil` when there is none. Run ids start with their UTC
  /// start time, so the greatest id is the newest.
  public func newestBuildRun() -> String? {
    BuildJoinReader(commonDirectory: commonDirectory).read(buildRunID: nil).runs.map(\.runID).max()
  }

  /// What every file ``read(buildRun:)`` reads holds now: each event store's files, the run's
  /// ledger log, returns and `run.json`, and the plan's ledger. Taken before a read, a moved
  /// snapshot means the next read differs.
  public func snapshot(buildRun: String) -> RunViewSnapshot {
    var files: [String: RunViewSnapshot.Stamp] = [:]
    Self.stamp(
      stateRoot.url(RunLayout.eventsDirectory),
      as: stateRoot.displayPath(RunLayout.eventsDirectory), into: &files)
    guard let layout = try? PlanStateLayout(commonDirectory: commonDirectory.path),
      let plan = plan(of: buildRun, under: layout), let paths = try? layout.plan(plan),
      let run = try? paths.buildRun(buildRun)
    else { return RunViewSnapshot(files: files) }
    for path in [paths.ledgerFile, paths.planFile] {
      Self.stamp(URL(filePath: path), as: display(path), into: &files)
    }
    // run.json, the ledger log and every return.
    Self.stamp(URL(filePath: run.directory), as: display(run.directory), into: &files)
    let ledger = (try? Data(contentsOf: URL(filePath: paths.ledgerFile)))
      .flatMap { try? LedgerJSON.decode($0) }
    if let ledger {
      var ignored: [RunView.Damage] = []
      for worktree in liveWorktrees(plan: plan, ledger: ledger, damage: &ignored) {
        let state = StateRootResolver.resolve(worktree: worktree)
        Self.stamp(
          state.url(RunLayout.eventsDirectory),
          as: "\(worktree.lastPathComponent)/\(RunLayout.eventsDirectory)", into: &files)
      }
    }
    return RunViewSnapshot(files: files)
  }

  /// The plan whose state holds `buildRun`.
  private func plan(of buildRun: String, under layout: PlanStateLayout) -> String? {
    let plans = (try? FileManager.default.contentsOfDirectory(atPath: layout.root)) ?? []
    return plans.sorted().first { plan in
      guard let run = try? layout.plan(plan).buildRun(buildRun) else { return false }
      return FileManager.default.fileExists(atPath: run.directory)
    }
  }

  /// Every regular file at or under `url`, keyed by `name` and its path below `url`.
  private static func stamp(
    _ url: URL, as name: String, into files: inout [String: RunViewSnapshot.Stamp]
  ) {
    let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
    func add(_ file: URL, _ key: String) {
      guard let values = try? file.resourceValues(forKeys: Set(keys)),
        values.isRegularFile == true
      else { return }
      let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
      files[key] = RunViewSnapshot.Stamp(
        bytes: values.fileSize ?? 0, modifiedNanoseconds: Int(modified * 1_000_000_000))
    }
    add(url, name)
    let base = url.standardizedFileURL.path
    guard
      let walk = FileManager.default.enumerator(
        at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
    else { return }
    for case let file as URL in walk {
      let path = file.standardizedFileURL.path
      add(file, path.hasPrefix(base) ? name + path.dropFirst(base.count) : path)
    }
  }

  /// Each `gate.run` of a worker's store that nothing names, by run id, with the task whose
  /// window holds its end: from the task's move to `in-progress` until it is `done` or
  /// `abandoned`, or open. A run inside no window, or inside more than 1, stays out: a store copied
  /// into the main checkout no longer says which task's worktree it came from.
  ///
  /// A fix window, from a task's `build merge --undo` until its next merge or its task's window
  /// ends, wins over those: the task's fixer runs then, while every task still in progress beside
  /// it holds the run too. A run inside more than 1 fix window stays out.
  ///
  /// A run a live task worktree's run store holds, by run id in `holders`, goes to that
  /// worktree's task before any window: concurrent tasks of a clone write to 1 shared store,
  /// where windows alone can't tell their runs apart.
  static func workerGateRuns(
    _ workerEvents: [HarnessEvent], events: [BuildEvent], named: Set<String>,
    holders: [String: String] = [:]
  ) -> [String: String] {
    typealias Window = (task: String, start: Date, end: Date?)
    var windows: [Window] = []
    var fixes: [Window] = []
    for event in events {
      switch event {
      case .transition(let move):
        if move.to == .inProgress, !windows.contains(where: { $0.task == move.task }) {
          windows.append((move.task, move.at, nil))
        } else if move.to == .done || move.to == .abandoned,
          let index = windows.firstIndex(where: { $0.task == move.task && $0.end == nil })
        {
          windows[index].end = move.at
        }
        if move.to == .done || move.to == .abandoned,
          let index = fixes.firstIndex(where: { $0.task == move.task && $0.end == nil })
        {
          fixes[index].end = move.at
        }
      case .undo(let undo):
        fixes.append((undo.task, undo.at, nil))
      case .merge(let merge):
        if let index = fixes.firstIndex(where: { $0.task == merge.task && $0.end == nil }) {
          fixes[index].end = merge.at
        }
      case .gate, .returnCheck:
        continue
      }
    }
    func holding(_ windows: [Window], _ time: Date) -> [Window] {
      windows.filter { $0.start <= time && $0.end.map { time <= $0 } ?? true }
    }
    var tasks: [String: String] = [:]
    for event in workerEvents {
      guard case .gateRun = event.payload, let runID = event.runID, !named.contains(runID)
      else { continue }
      if let holder = holders[runID] {
        tasks[runID] = holder
        continue
      }
      let fixing = holding(fixes, event.time)
      let holds = fixing.isEmpty ? holding(windows, event.time) : fixing
      if holds.count == 1, let window = holds.first { tasks[runID] = window.task }
    }
    return tasks
  }

  /// Every gate run the run's ledger log or its returns name.
  static func gateRuns(of run: BuildJoin.Run) -> Set<String> {
    var runs = Set(run.returns.values.compactMap { $0.gate?.runID })
    for event in run.events {
      if case .gate(let gate) = event { runs.insert(gate.runID) }
    }
    return runs
  }

  /// The kept events a `span.end` or a `prove.result` names as its parent.
  struct Parents {
    /// The `span.start`s of the run, by span id.
    var spans: Set<String> = []
    /// The `gate.run`s of the run's gate runs, by event id.
    var gateRuns: Set<String> = []

    init(
      _ events: [HarnessEvent], buildRun: String, gateRuns runs: Set<String>,
      prebuild: Prebuild = Prebuild()
    ) {
      for event in events {
        switch event.payload {
        case .spanStart(let span) where span.buildRun == buildRun || span.buildRun == prebuild.slug:
          spans.insert(span.spanID)
        case .gateRun where event.runID.map(runs.contains) == true:
          gateRuns.insert(event.eventID)
        default:
          continue
        }
      }
    }
  }

  static func belongs(
    _ event: HarnessEvent, buildRun: String, gateRuns: Set<String>, parents: Parents,
    prebuild: Prebuild = Prebuild()
  ) -> Bool {
    let named: (String?) -> Bool = { $0.map(gateRuns.contains) ?? false }
    switch event.payload {
    case .buildHalt(let halt): return halt.buildRun == buildRun
    case .buildResume(let resume): return resume.buildRun == buildRun
    case .buildReturnChecked(let checked): return checked.buildRun == buildRun
    case .agentUsage(let usage): return usage.buildRun == buildRun
    case .agentTools(let tools): return tools.buildRun == buildRun
    case .spanStart(let span): return span.buildRun == buildRun || span.buildRun == prebuild.slug
    case .spanEnd(let span): return parents.spans.contains(span.spanID)
    case .gateRun, .gateStep, .testResult: return named(event.runID)
    case .proveResult:
      return named(event.runID) || event.parentID.map(parents.gateRuns.contains) ?? false
    case .discoverRun, .warmupRun: return prebuild.holds(event.time)
    case .judgeDecision, .judgeCall, .hookDecision, .cacheLookup:
      return false
    }
  }

  /// Each run a live task worktree's run store holds, by run id, with the worktree's task: a fix
  /// worktree's runs go to the task it fixes. A run 2 worktrees hold goes to neither.
  private func runHolders(plan: String, ledger: Ledger) -> [String: String] {
    var holders: [String: String] = [:]
    var shared = Set<String>()
    for task in ledger.tasks {
      for name in [task.id, "fix-\(task.id)"] {
        guard
          let path = try? TaskWorktree(
            commonDirectory: commonDirectory.path, plan: plan, task: name, profile: profile
          ).path
        else { continue }
        let worktree = URL(filePath: path, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: path) else { continue }
        let runs = StateRootResolver.resolve(worktree: worktree).url(
          RunLayout.runsDirectory, directoryHint: .isDirectory)
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: runs.path)) ?? []
        for id in ids where RunID.isValid(id) {
          if let other = holders[id], other != task.id { shared.insert(id) }
          holders[id] = task.id
        }
      }
    }
    for id in shared { holders[id] = nil }
    return holders
  }

  /// The task worktrees of `plan` that exist now, a fix worktree included. In a brownfield clone,
  /// also the plan branch's checkout, where merges and their gates run, unless it is this
  /// checkout, whose store is already read.
  private func liveWorktrees(plan: String, ledger: Ledger, damage: inout [RunView.Damage]) -> [URL]
  {
    var paths: [String] = []
    do {
      for task in ledger.tasks {
        for name in [task.id, "fix-\(task.id)"] {
          paths.append(
            try TaskWorktree(
              commonDirectory: commonDirectory.path, plan: plan, task: name, profile: profile
            ).path)
        }
      }
      if profile == .brownfield, let first = ledger.tasks.first {
        let checkout = try TaskWorktree(
          commonDirectory: commonDirectory.path, plan: plan, task: first.id, profile: profile
        ).mainCheckout
        let state = StateRootResolver.resolve(
          worktree: URL(filePath: checkout, directoryHint: .isDirectory))
        if state.directory.standardizedFileURL != stateRoot.directory.standardizedFileURL {
          paths.append(checkout)
        }
      }
    } catch {
      damage.append(
        RunView.Damage(
          source: commonDirectory.lastPathComponent,
          reason: "task worktrees can't be named: \(error)"))
    }
    return paths.filter { path in
      var isDirectory: ObjCBool = false
      return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        && isDirectory.boolValue
    }.map { URL(filePath: $0, directoryHint: .isDirectory) }
  }

  private struct PlanState {
    var ledger: Ledger?
    var requirements: [RunViewRequirement] = []
    var briefs: [String: RunView.Brief] = [:]
  }

  /// - Throws: ``PlanStateLayoutError`` for a relative common dir, a caller's mistake.
  private func planState(_ plan: String, damage: inout [RunView.Damage]) throws -> PlanState {
    var state = PlanState()
    let paths = try PlanStateLayout(commonDirectory: commonDirectory.path).plan(plan)
    // The build join reads the same file and already names it when it's missing or undecodable.
    state.ledger = (try? Data(contentsOf: URL(filePath: paths.ledgerFile)))
      .flatMap { try? LedgerJSON.decode($0) }
    guard let data = read(paths.planFile, damage: &damage) else { return state }
    let file: PlanFile
    do {
      file = try PlanFileJSON.decode(data)
    } catch {
      damage.append(RunView.Damage(source: display(paths.planFile), reason: "\(error)"))
      return state
    }
    switch file.source {
    case .specPage(let page):
      let path = "\(paths.directory)/\(page.path)"
      guard let data = read(path, damage: &damage) else { return state }
      switch SpecPage.parse(String(decoding: data, as: UTF8.self)) {
      case .parsed(let parsed):
        state.requirements = parsed.slices.map { slice in
          let title: String
          switch slice.spec {
          case .quote(let quote): title = quote
          case .none: title = slice.testName
          }
          return RunViewRequirement(id: slice.id, title: Self.cut(title))
        }
      case .malformed(let problems):
        damage.append(
          RunView.Damage(
            source: display(path),
            reason: "malformed spec page: \(problems.map(\.message).joined(separator: "; "))"))
      }
    case .design(let design):
      let checkout: String
      do {
        checkout = try TaskWorktree.mainCheckout(commonDirectory: commonDirectory.path)
      } catch {
        damage.append(RunView.Damage(source: design.design, reason: "\(error)"))
        return state
      }
      let url = URL(filePath: checkout, directoryHint: .isDirectory).appending(path: design.design)
      guard let data = read(url.path, damage: &damage, source: design.design) else {
        return state
      }
      let document = DesignDocument(
        markdown: MarkdownDocument.parse(String(decoding: data, as: UTF8.self)))
      state.requirements = document.requirements.map {
        RunViewRequirement(id: $0.id, title: Self.cut($0.statement))
      }
    case .livePlan(let live):
      state.requirements = live.requirements.map {
        RunViewRequirement(id: $0.id, title: Self.cut($0.title))
      }
      state.briefs = live.briefs.mapValues {
        RunView.Brief(
          title: $0.title, why: $0.why ?? "", designRef: $0.designRef, scope: $0.scope,
          acceptance: $0.acceptance, outOfScope: $0.outOfScope)
      }
    }
    return state
  }

  /// The file's bytes; damage when it is missing or doesn't read.
  private func read(_ path: String, damage: inout [RunView.Damage], source: String? = nil)
    -> Data?
  {
    do {
      return try Data(contentsOf: URL(filePath: path))
    } catch {
      damage.append(
        RunView.Damage(source: source ?? display(path), reason: error.localizedDescription))
      return nil
    }
  }

  /// `path`, under the common dir, relative to it.
  private func display(_ path: String) -> String {
    let prefix =
      commonDirectory.path.hasSuffix("/") ? commonDirectory.path : commonDirectory.path + "/"
    return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
  }

  private static func damage(_ damage: EventDamage, in worktree: String?) -> RunView.Damage {
    var file = damage.file
    if let worktree, !file.hasPrefix("/") { file = "\(worktree)/\(file)" }
    var reason = damage.kind.rawValue
    if let detail = damage.detail { reason += ": \(detail)" }
    return RunView.Damage(source: damage.line.map { "\(file):\($0)" } ?? file, reason: reason)
  }

  /// `text` cut to at most ``RunView/maxTitleBytes`` UTF-8 bytes, on a character boundary.
  static func cut(_ text: String) -> String {
    guard text.utf8.count > RunView.maxTitleBytes else { return text }
    var result = ""
    var bytes = 0
    for character in text {
      let size = character.utf8.count
      guard bytes + size <= RunView.maxTitleBytes else { break }
      result.append(character)
      bytes += size
    }
    return result
  }
}

/// ``RunLayout`` paths under 1 ``StateRoot``, named as ``StateRoot/displayPath(_:)`` names them.
private struct StateRootEventFiles: EventStoreFileReading {
  let state: StateRoot
  /// Whether `imported/` and `unkept/` list their stores.
  var includeCopies = true
  static let copyDirectories: Set<String> = [
    "\(RunLayout.eventsDirectory)/imported", "\(RunLayout.eventsDirectory)/unkept",
  ]

  func displayPath(_ path: String) -> String { state.displayPath(path) }

  func read(_ path: String) throws(EventStoreFileError) -> Data? {
    do {
      return try Data(contentsOf: state.url(path))
    } catch CocoaError.fileReadNoSuchFile {
      return nil
    } catch {
      throw EventStoreFileError(path: state.displayPath(path), reason: error.localizedDescription)
    }
  }

  func list(_ directory: String) throws(EventStoreFileError) -> [String] {
    if !includeCopies, Self.copyDirectories.contains(directory) { return [] }
    do {
      return try FileManager.default.contentsOfDirectory(atPath: state.url(directory).path)
        .sorted()
    } catch CocoaError.fileReadNoSuchFile {
      return []
    } catch {
      throw EventStoreFileError(
        path: state.displayPath(directory), reason: error.localizedDescription)
    }
  }

  func size(_ path: String) throws(EventStoreFileError) -> Int? {
    var info = stat()
    guard stat(state.url(path).path, &info) == 0 else {
      if errno == ENOENT { return nil }
      throw EventStoreFileError(
        path: state.displayPath(path), reason: String(cString: strerror(errno)))
    }
    return Int(info.st_size)
  }
}

import Darwin
import Foundation
import SwiftGateDomain

/// Reads the main store, each live task worktree's store and every imported store, the build join
/// and the plan, filtered to 1 build run.
///
/// An event belongs to the run when its payload names the run (`build.halt`, `build.resume`,
/// `agent.usage`, `agent.tools`, `span.*`), or when it is a gate event (`gate.run`, `gate.step`,
/// `test.result`, `prove.result`) of a gate run the run's ledger log or a task return names. No
/// other event names a build run, so none other is kept.
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
    if let join {
      let plan = try planState(join.plan, damage: &damage)
      ledger = plan.ledger
      requirements = plan.requirements
      briefs = plan.briefs
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
    var workerEvents = main.events.map(\.event).filter { !mainOwn.contains($0.eventID) }
    if let join, let ledger {
      for worktree in liveWorktrees(plan: join.plan, ledger: ledger, damage: &damage) {
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
      join.map { Self.workerGateRuns(workerEvents, events: $0.events, named: gateRuns) } ?? [:]
    gateRuns.formUnion(workerGateRuns.keys)
    let events = EventQuery.merge(batches).map(\.event)
    let parents = Parents(events, buildRun: buildRun, gateRuns: gateRuns)
    return RunViewInput(
      buildRun: buildRun,
      events: events.filter {
        Self.belongs($0, buildRun: buildRun, gateRuns: gateRuns, parents: parents)
      },
      join: join, ledger: ledger, requirements: requirements, damage: damage, briefs: briefs,
      workerGateRuns: workerGateRuns)
  }

  /// Each `gate.run` of a worker's store that nothing names, by run id, with the task whose
  /// window holds its end: from the task's move to `in-progress` until it is `done` or
  /// `abandoned`, or open. A run inside no window, or inside more than 1, stays out: a store copied
  /// into the main checkout no longer says which task's worktree it came from.
  static func workerGateRuns(
    _ workerEvents: [HarnessEvent], events: [BuildEvent], named: Set<String>
  ) -> [String: String] {
    var windows: [(task: String, start: Date, end: Date?)] = []
    for event in events {
      guard case .transition(let move) = event else { continue }
      if move.to == .inProgress, !windows.contains(where: { $0.task == move.task }) {
        windows.append((move.task, move.at, nil))
      } else if move.to == .done || move.to == .abandoned,
        let index = windows.firstIndex(where: { $0.task == move.task && $0.end == nil })
      {
        windows[index].end = move.at
      }
    }
    var tasks: [String: String] = [:]
    for event in workerEvents {
      guard case .gateRun = event.payload, let runID = event.runID, !named.contains(runID)
      else { continue }
      let holding = windows.filter {
        $0.start <= event.time && $0.end.map { event.time <= $0 } ?? true
      }
      if holding.count == 1, let window = holding.first { tasks[runID] = window.task }
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

    init(_ events: [HarnessEvent], buildRun: String, gateRuns runs: Set<String>) {
      for event in events {
        switch event.payload {
        case .spanStart(let span) where span.buildRun == buildRun:
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
    _ event: HarnessEvent, buildRun: String, gateRuns: Set<String>, parents: Parents
  ) -> Bool {
    let named: (String?) -> Bool = { $0.map(gateRuns.contains) ?? false }
    switch event.payload {
    case .buildHalt(let halt): return halt.buildRun == buildRun
    case .buildResume(let resume): return resume.buildRun == buildRun
    case .agentUsage(let usage): return usage.buildRun == buildRun
    case .agentTools(let tools): return tools.buildRun == buildRun
    case .spanStart(let span): return span.buildRun == buildRun
    case .spanEnd(let span): return parents.spans.contains(span.spanID)
    case .gateRun, .gateStep, .testResult: return named(event.runID)
    case .proveResult:
      return named(event.runID) || event.parentID.map(parents.gateRuns.contains) ?? false
    case .judgeDecision, .judgeCall, .hookDecision, .cacheLookup, .discoverRun, .warmupRun:
      return false
    }
  }

  /// The task worktrees of `plan` that exist now, a fix worktree included.
  private func liveWorktrees(plan: String, ledger: Ledger, damage: inout [RunView.Damage]) -> [URL]
  {
    var worktrees: [URL] = []
    for task in ledger.tasks {
      for name in [task.id, "fix-\(task.id)"] {
        let path: String
        do {
          path = try TaskWorktree(
            commonDirectory: commonDirectory.path, plan: plan, task: name
          ).path
        } catch {
          damage.append(
            RunView.Damage(
              source: commonDirectory.lastPathComponent,
              reason: "task worktrees can't be named: \(error)"))
          return worktrees
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
          isDirectory.boolValue
        {
          worktrees.append(URL(filePath: path, directoryHint: .isDirectory))
        }
      }
    }
    return worktrees
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
      // A live plan names no requirements of its own, only each task's brief.
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

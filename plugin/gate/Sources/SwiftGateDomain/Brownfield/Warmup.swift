import Foundation

/// 1 warm-up step as it ran.
public struct WarmupStepResult: Sendable, Equatable {
  public let step: WarmupStep
  public let milliseconds: Int
  public let cache: WarmupCache
  public let outcome: WarmupOutcome
  /// The end of the step's output when it failed, or why it didn't run; `nil` when it passed.
  public let detail: String?

  public init(
    step: WarmupStep, milliseconds: Int, cache: WarmupCache, outcome: WarmupOutcome,
    detail: String?
  ) {
    self.step = step
    self.milliseconds = milliseconds
    self.cache = cache
    self.outcome = outcome
    self.detail = detail
  }
}

/// The build and test 1 area ran in the tree that holds its project.
public struct WarmupTreeRun: Sendable, Equatable {
  public let steps: [WarmupStepResult]
  /// The base tree's answers for the steps that ran, keyed as every gate keys them.
  public let baseline: [BaselineRecord]

  public init(steps: [WarmupStepResult], baseline: [BaselineRecord]) {
    self.steps = steps
    self.baseline = baseline
  }
}

/// What an XcodeGen or Tuist area's generate step came to.
public enum WarmupGeneration: Sendable, Equatable {
  /// The project generated, and `run` is the build and test that ran in its tree.
  case generated(milliseconds: Int, run: WarmupTreeRun)
  /// `outcome` is `failed` or `notInstalled`; no build or test ran.
  case notGenerated(milliseconds: Int, outcome: WarmupOutcome, detail: String)
}

/// 1 area's entry in `warmup/<tree>.json`.
public struct WarmupAreaRecord: Sendable, Equatable {
  /// The first warm-up's steps together at this tree: the area's cost on empty caches.
  public let coldMilliseconds: Int
  /// The latest test run's time, its build already warm, whatever it came to; `nil` when no test
  /// has run. A gate budgets with ``warmTestMilliseconds``.
  public let testMilliseconds: Int?
  /// The latest outcome of each step the warm-up ran or dropped.
  public let steps: [WarmupStep: WarmupOutcome]

  public init(coldMilliseconds: Int, testMilliseconds: Int?, steps: [WarmupStep: WarmupOutcome]) {
    self.coldMilliseconds = coldMilliseconds
    self.testMilliseconds = testMilliseconds
    self.steps = steps
  }

  /// The warm test time a gate may budget with: only a test step that passed measured one.
  public var warmTestMilliseconds: Int? {
    steps[.test] == .passed ? testMilliseconds : nil
  }
}

/// 1 area's warm-up.
public struct WarmupAreaResult: Sendable, Equatable {
  public let area: String
  public let steps: [WarmupStepResult]
  /// For `baseline/<tree>.json`.
  public let baseline: [BaselineRecord]
  /// What `warmup/<tree>.json` keeps for the area after this run.
  public let record: WarmupAreaRecord

  public init(
    area: String, steps: [WarmupStepResult], baseline: [BaselineRecord], record: WarmupAreaRecord
  ) {
    self.area = area
    self.steps = steps
    self.baseline = baseline
    self.record = record
  }

  /// 1 `warmup.run` per step.
  public var events: [WarmupRunEvent] {
    steps.map {
      WarmupRunEvent(
        area: area, step: $0.step, milliseconds: $0.milliseconds, cache: $0.cache,
        outcome: $0.outcome)
    }
  }
}

public struct WarmupTimesFileError: Error, Sendable, Equatable {
  public let detail: String

  public init(detail: String) { self.detail = detail }
}

/// `warmup/<tree>.json`: each area's warm test time and cold cost at 1 base tree.
public struct WarmupTimesFile: Sendable, Equatable {
  public static let version = 1

  public let tree: String
  public private(set) var areas: [String: WarmupAreaRecord]

  public init(tree: String, areas: [String: WarmupAreaRecord] = [:]) {
    self.tree = tree
    self.areas = areas
  }

  /// Fails on a step or outcome it doesn't know, and on a file recorded for another tree.
  public static func decode(_ data: Data, tree: String) throws(WarmupTimesFileError)
    -> WarmupTimesFile
  {
    let stored: StoredFile
    do {
      stored = try JSONDecoder().decode(StoredFile.self, from: data)
    } catch {
      throw WarmupTimesFileError(detail: "\(error)")
    }
    guard stored.version == version else {
      throw WarmupTimesFileError(detail: "version \(stored.version), expected \(version)")
    }
    guard stored.tree == tree else {
      throw WarmupTimesFileError(detail: "recorded for tree \(stored.tree), expected \(tree)")
    }
    var areas: [String: WarmupAreaRecord] = [:]
    for (name, area) in stored.areas {
      var steps: [WarmupStep: WarmupOutcome] = [:]
      for (raw, outcome) in area.steps {
        guard let step = WarmupStep(rawValue: raw) else {
          throw WarmupTimesFileError(
            detail: "\(name): unknown step \(raw), expected one of "
              + WarmupStep.allCases.map(\.rawValue).joined(separator: ", "))
        }
        steps[step] = outcome
      }
      areas[name] = WarmupAreaRecord(
        coldMilliseconds: area.coldMs, testMilliseconds: area.testMs, steps: steps)
    }
    return WarmupTimesFile(tree: tree, areas: areas)
  }

  public func encoded() -> Data {
    let stored = StoredFile(
      version: Self.version, tree: tree,
      areas: areas.mapValues { record in
        StoredArea(
          coldMs: record.coldMilliseconds, testMs: record.testMilliseconds,
          steps: Dictionary(uniqueKeysWithValues: record.steps.map { ($0.key.rawValue, $0.value) }))
      })
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    // Every field is a string, an int or a map of them, which always encode.
    return (try? encoder.encode(stored)) ?? Data()
  }

  /// A newer record for an area replaces the older one.
  public mutating func merge(area: String, record: WarmupAreaRecord) {
    areas[area] = record
  }

  /// `true` when `area`'s warm test time doesn't fit `budgetSeconds`, or no warm-up measured it:
  /// `slice` then only builds the area, and its tests and their prove move to `merge`.
  public func buildsOnly(_ area: String, budgetSeconds: Int) -> Bool {
    guard let test = areas[area]?.warmTestMilliseconds else { return true }
    return test > budgetSeconds * 1_000
  }

  private struct StoredArea: Codable {
    let coldMs: Int
    let testMs: Int?
    let steps: [String: WarmupOutcome]
  }

  private struct StoredFile: Codable {
    let version: Int
    let tree: String
    let areas: [String: StoredArea]
  }
}

/// Runs every area's generate, build and test at the base tree, all areas at once, each to its
/// end, so the shared caches fill and the times and baseline serve the run that follows.
public enum Warmup {
  public struct Dependencies: Sendable {
    public let layout: BrownfieldStateLayout
    /// Absolute: the worktree's toplevel.
    public let repositoryRoot: String
    /// The tracked files, for each area's shared cache variables.
    public let trackedTree: TrackedTreeSnapshot
    /// What earlier warm-ups recorded at this tree: a step it holds runs `warm`.
    public let known: WarmupTimesFile
    /// Per command run.
    public let deadline: Duration
    public let run: @Sendable (AreaCommandRequest) async -> AreaCommandOutcome
    /// Generates `area`'s project and runs `body` in the toplevel of the tree holding it.
    public let generate:
      @Sendable (
        _ area: BrownfieldArea,
        _ body: @escaping @Sendable (_ toplevel: String) async -> WarmupTreeRun
      ) async -> WarmupGeneration
    /// Handed each area as it ends, so its times land before a slower area finishes.
    public let finished: @Sendable (WarmupAreaResult) async -> Void

    public init(
      layout: BrownfieldStateLayout, repositoryRoot: String, trackedTree: TrackedTreeSnapshot,
      known: WarmupTimesFile, deadline: Duration,
      run: @escaping @Sendable (AreaCommandRequest) async -> AreaCommandOutcome,
      generate:
        @escaping @Sendable (
          _ area: BrownfieldArea,
          _ body: @escaping @Sendable (_ toplevel: String) async -> WarmupTreeRun
        ) async -> WarmupGeneration,
      finished: @escaping @Sendable (WarmupAreaResult) async -> Void
    ) {
      self.layout = layout
      self.repositoryRoot = repositoryRoot
      self.trackedTree = trackedTree
      self.known = known
      self.deadline = deadline
      self.run = run
      self.generate = generate
      self.finished = finished
    }
  }

  /// Every area in parallel; the results in `areas`' order.
  public static func run(areas: [BrownfieldArea], dependencies: Dependencies) async
    -> [WarmupAreaResult]
  {
    let results = await withTaskGroup(of: (Int, WarmupAreaResult).self) { group in
      for (index, area) in areas.enumerated() {
        group.addTask { (index, await run(area: area, dependencies: dependencies)) }
      }
      var results: [(Int, WarmupAreaResult)] = []
      for await result in group { results.append(result) }
      return results
    }
    return results.sorted { $0.0 < $1.0 }.map(\.1)
  }

  /// 1 area: `generate` for XcodeGen and Tuist, then `build`, then `test`. A generate that
  /// doesn't produce a project ends the area there.
  public static func run(area: BrownfieldArea, dependencies: Dependencies) async
    -> WarmupAreaResult
  {
    let treeRun: WarmupTreeRun
    var steps: [WarmupStepResult] = []
    if let inclusion = area.xcode?.inclusion, inclusion == .xcodegen || inclusion == .tuist {
      let generation = await dependencies.generate(area) { toplevel in
        await buildAndTest(area, toplevel: toplevel, dependencies: dependencies)
      }
      let cache = cache(area.name, .generate, dependencies.known)
      switch generation {
      case .generated(let milliseconds, let run):
        steps.append(
          WarmupStepResult(
            step: .generate, milliseconds: milliseconds, cache: cache, outcome: .passed,
            detail: nil))
        treeRun = run
      case .notGenerated(let milliseconds, let outcome, let detail):
        steps.append(
          WarmupStepResult(
            step: .generate, milliseconds: milliseconds, cache: cache, outcome: outcome,
            detail: detail))
        treeRun = WarmupTreeRun(steps: [], baseline: [])
      }
    } else {
      treeRun = await buildAndTest(
        area, toplevel: dependencies.repositoryRoot, dependencies: dependencies)
    }
    steps += treeRun.steps
    let result = WarmupAreaResult(
      area: area.name, steps: steps, baseline: treeRun.baseline,
      record: record(area.name, steps: steps, known: dependencies.known))
    await dependencies.finished(result)
    return result
  }

  /// Whether the repository commits `xcode`'s generated project, so generating it in place would
  /// show the user a diff.
  public static func generatedProjectTracked(_ xcode: XcodeAreaConfig, tree: TrackedTreeSnapshot)
    -> Bool
  {
    guard let container = xcode.project ?? xcode.workspace else { return false }
    let prefix = container.split(separator: "/").filter { $0 != "." }.joined(separator: "/") + "/"
    return tree.paths.contains { $0.hasPrefix(prefix) }
  }

  /// `build`, then `test`, in the tree whose toplevel is `toplevel`. The test runs after a failed
  /// build too: its failure is the base tree's answer the baseline needs.
  private static func buildAndTest(
    _ area: BrownfieldArea, toplevel: String, dependencies: Dependencies
  ) async -> WarmupTreeRun {
    var steps: [WarmupStepResult] = []
    var baseline: [BaselineRecord] = []
    let environment = AreaCacheEnvironment.make(
      area: area, layout: dependencies.layout, tree: dependencies.trackedTree
    ).variables
    for (step, areaStep) in [(WarmupStep.build, AreaStep.build), (.test, .test)] {
      let cache = cache(area.name, step, dependencies.known)
      guard
        let template = AreaCommandExpansion.template(for: areaStep, in: area),
        let prepared = AreaCommandExpansion.prepare(
          area: area, step: areaStep, repositoryRoot: toplevel, files: [], tests: [],
          junitPath: AreaCommandExpansion.junitPath(
            layout: dependencies.layout, area: area.name, step: areaStep),
          deadline: dependencies.deadline, environment: environment)
      else {
        steps.append(
          WarmupStepResult(
            step: step, milliseconds: 0, cache: cache, outcome: .dropped,
            detail: "no \(areaStep.rawValue) command in the config"))
        continue
      }
      let started = ContinuousClock.now
      let outcome = await dependencies.run(prepared.request)
      let milliseconds = Self.milliseconds(ContinuousClock.now - started)
      steps.append(
        WarmupStepResult(
          step: step, milliseconds: milliseconds, cache: cache,
          outcome: outcome == .passed
            ? .passed : outcome.toolNotInstalled ? .notInstalled : .failed,
          detail: detail(outcome)))
      baseline.append(
        BaselineRecord(
          key: BaselineStepKey(area: area.name, step: areaStep, command: template),
          result: BaselineStepResult.of(outcome)))
    }
    return WarmupTreeRun(steps: steps, baseline: baseline)
  }

  /// `warm` once an earlier warm-up at this tree ran the step, whatever it came to: the caches it
  /// fills are filled either way.
  private static func cache(_ area: String, _ step: WarmupStep, _ known: WarmupTimesFile)
    -> WarmupCache
  {
    switch known.areas[area]?.steps[step] {
    case .passed?, .failed?: .warm
    case .dropped?, .notInstalled?, nil: .cold
    }
  }

  /// The cold cost stays that of the first run that built; the test time and outcomes are this
  /// run's.
  private static func record(
    _ area: String, steps: [WarmupStepResult], known: WarmupTimesFile
  ) -> WarmupAreaRecord {
    let earlier = known.areas[area]
    let ran = steps.filter { $0.outcome == .passed || $0.outcome == .failed }
    let test = ran.first { $0.step == .test }?.milliseconds
    var outcomes = earlier?.steps ?? [:]
    for step in steps { outcomes[step.step] = step.outcome }
    let earlierBuilt = earlier?.steps[.build] == .passed || earlier?.steps[.build] == .failed
    let cold =
      earlierBuilt ? earlier?.coldMilliseconds : nil
    return WarmupAreaRecord(
      coldMilliseconds: cold ?? ran.reduce(0) { $0 + $1.milliseconds },
      testMilliseconds: test ?? earlier?.testMilliseconds, steps: outcomes)
  }

  private static func detail(_ outcome: AreaCommandOutcome) -> String? {
    switch outcome {
    case .passed: nil
    case .failed(_, let tail, _): tail
    case .crashed(let signal, let tail):
      "crashed\(signal.map { " on signal \($0)" } ?? ""):\n\(tail)"
    case .timedOut(let tail): "timed out:\n\(tail)"
    }
  }

  private static func milliseconds(_ duration: Duration) -> Int {
    Int(
      duration.components.seconds * 1_000
        + duration.components.attoseconds / 1_000_000_000_000_000)
  }
}

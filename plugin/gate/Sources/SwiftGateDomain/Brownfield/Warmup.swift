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
  /// The latest test run's time, its build already warm; `nil` when no test has run.
  public let testMilliseconds: Int?
  /// The latest outcome of each step the warm-up ran or dropped.
  public let steps: [WarmupStep: WarmupOutcome]

  public init(coldMilliseconds: Int, testMilliseconds: Int?, steps: [WarmupStep: WarmupOutcome]) {
    self.coldMilliseconds = coldMilliseconds
    self.testMilliseconds = testMilliseconds
    self.steps = steps
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
    []
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
    WarmupTimesFile(tree: tree)
  }

  public func encoded() -> Data {
    Data()
  }

  /// A newer record for an area replaces the older one.
  public mutating func merge(area: String, record: WarmupAreaRecord) {}

  /// `true` when `area`'s warm test time doesn't fit `budgetSeconds`, or no warm-up measured it:
  /// `slice` then only builds the area, and its tests and their prove move to `merge`.
  public func buildsOnly(_ area: String, budgetSeconds: Int) -> Bool {
    true
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
    []
  }

  /// 1 area: `generate` for XcodeGen and Tuist, then `build`, then `test`.
  public static func run(area: BrownfieldArea, dependencies: Dependencies) async
    -> WarmupAreaResult
  {
    WarmupAreaResult(
      area: area.name, steps: [], baseline: [],
      record: WarmupAreaRecord(coldMilliseconds: 0, testMilliseconds: nil, steps: [:]))
  }

  /// Whether the repository commits `xcode`'s generated project, so generating it in place would
  /// show the user a diff.
  public static func generatedProjectTracked(_ xcode: XcodeAreaConfig, tree: TrackedTreeSnapshot)
    -> Bool
  {
    false
  }
}

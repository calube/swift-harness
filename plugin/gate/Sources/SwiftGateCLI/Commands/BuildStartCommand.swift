import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// What a build loop command did: its report when it acted, or why it refused.
struct BuildLoopResult<Report: Encodable & Sendable>: Sendable {
  let command: String
  let plan: String
  let verdict: Verdict
  let report: Report?
  /// The session holding the plan's lock, when a refusal is because it isn't the caller.
  let holder: String?
  let message: String

  static func refused(
    _ command: String, _ plan: String, _ verdict: Verdict, _ message: String,
    holder: String? = nil
  ) -> Self {
    Self(
      command: command, plan: plan, verdict: verdict, report: nil, holder: holder,
      message: message)
  }

  static func blocked(_ command: String, _ plan: String, _ message: String) -> Self {
    refused(command, plan, .blocked, message)
  }
}

/// Plumbing the build loop commands share: the lock-holder check `index set` makes, reading plan
/// state, and setting the index through `index set`'s own path.
enum BuildLoop {
  /// `nil` when `session` holds `slug`'s lock; otherwise the refusal to return.
  static func authorize<Report>(
    _ command: String, slug: String, session: String?, git: any Git
  ) async -> BuildLoopResult<Report>? {
    guard let refusal = await IndexSetAuthority.check(slug: slug, session: session, git: git)
    else { return nil }
    switch refusal {
    case .missingSession:
      return .blocked(
        command, slug,
        "--session is required: pass the id, from the SessionStart context, of the session "
          + "holding plan `\(slug)`")
    case .invalidSession(let value):
      return .blocked(
        command, slug, "--session `\(value)` must be a non-empty id without whitespace")
    case .notHolder(let current?):
      return .refused(
        command, slug, .red, PlanLockRun.heldByOtherMessage(slug, current), holder: current)
    case .notHolder(nil):
      return .refused(
        command, slug, .red,
        "plan `\(slug)` isn't claimed; only the session holding its lock runs its build. "
          + "Claim it with `swiftgate plan claim \(slug) --session <id>` first.")
    case .blocked(let detail):
      return .blocked(command, slug, detail)
    }
  }

  static func planLayout(_ slug: String, git: any Git) async throws(BuildLoopError)
    -> PlanStateLayout
  {
    do {
      return try PlanStateLayout(commonDirectory: try await git.commonDirectory())
    } catch {
      throw BuildLoopError("can't place plan `\(slug)` under the git common dir: \(error)")
    }
  }

  static func ledger(_ plan: PlanStateLayout.Plan) throws(BuildLoopError) -> Ledger {
    do {
      return try LedgerJSON.decode(try Data(contentsOf: URL(filePath: plan.ledgerFile)))
    } catch {
      throw BuildLoopError("\(plan.ledgerFile) can't be read or decoded: \(error)")
    }
  }

  /// `slug`'s index entry, or `nil` when the index or the entry doesn't exist.
  static func indexEntry(_ slug: String, layout: PlanStateLayout) throws(BuildLoopError)
    -> PlanSummary?
  {
    let data: Data
    do {
      data = try Data(contentsOf: URL(filePath: layout.indexFile))
    } catch CocoaError.fileReadNoSuchFile {
      return nil
    } catch {
      throw BuildLoopError("\(layout.indexFile) can't be read: \(error)")
    }
    do {
      return try PlanIndex.decode(data).plans.first { $0.slug == slug }
    } catch {
      throw BuildLoopError("\(layout.indexFile) can't be decoded: \(error)")
    }
  }

  /// Sets the index as `index set` does. The caller has already passed ``authorize(_:slug:session:git:)``.
  static func setIndex(_ slug: String, _ status: PlanStatus, resume: String, git: any Git)
    async throws(BuildLoopError)
  {
    if case .failure(let error) = await IndexSetRun.run(
      slug: slug, status: status.rawValue, resume: resume, git: git)
    {
      throw BuildLoopError("setting the index to \(status.rawValue): \(error)")
    }
  }

  private struct Refusal: Encodable {
    let command: String
    let plan: String
    let verdict: Verdict
    let holder: String?
    let message: String
  }

  /// JSON is the report itself when the command acted, else `{command, plan, verdict, holder?,
  /// message}`.
  static func render<Report>(
    _ result: BuildLoopResult<Report>, format: OutputFormat, human: (Report) -> String
  ) -> String {
    switch format {
    case .json:
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      encoder.dateEncodingStrategy = .iso8601
      let data: Data?
      if let report = result.report {
        data = try? encoder.encode(report)
      } else {
        data = try? encoder.encode(
          Refusal(
            command: result.command, plan: result.plan, verdict: result.verdict,
            holder: result.holder, message: result.message))
      }
      return String(decoding: data ?? Data(), as: UTF8.self)
    case .human:
      guard let report = result.report else {
        return "\(result.command): \(result.verdict.rawValue) \(result.message)"
      }
      return human(report)
    }
  }

  static func exit<Report>(_ result: BuildLoopResult<Report>) throws {
    if result.verdict != .green { throw ExitCode(result.verdict.exitCode) }
  }

  static func git() -> LiveGit {
    LiveGit(
      runner: LiveProcessRunner(), repositoryRoot: FileManager.default.currentDirectoryPath)
  }
}

struct BuildLoopError: Error, Sendable {
  let message: String
  init(_ message: String) { self.message = message }
}

struct BuildStartReport: Sendable, Equatable, Encodable {
  let command: String
  let plan: String
  let runId: String
  let presetName: String
  let indexStatus: PlanStatus
}

/// The presets a repository defines, and the profile whose config they came from.
struct BuildPresetCatalog: Sendable, Equatable {
  /// The only preset a brownfield clone runs, and a name an owned repository can't use.
  static let brownfieldPresetName = "brownfield"

  let profile: RepositoryProfile
  let presets: [String: BuildPreset]
  /// The config file the presets came from, as a refusal names it.
  let file: String

  static func owned(_ presets: [String: BuildPreset]) -> Self {
    Self(profile: .owned, presets: presets, file: ConfigLoader.fileName)
  }

  /// The profile of the repository holding `root`, decided as ``load(root:git:)`` decides it: by
  /// which config file exists, without parsing either.
  static func profile(root: URL) -> RepositoryProfile {
    switch StateRootResolver.resolve(worktree: root) {
    case .tree: .owned
    case .gitDir: .brownfield
    }
  }

  /// An owned repository's `.swiftgate.toml`, or a brownfield clone's `config.toml` under the git
  /// common dir, chosen as ``StateRootResolver`` chooses the state root.
  static func load(root: URL, git: any Git) async throws(BuildLoopError) -> Self {
    guard profile(root: root) == .brownfield else {
      do {
        return .owned(try ConfigLoader().load(repositoryRoot: root)?.buildPresets ?? [:])
      } catch {
        throw BuildLoopError("can't load \(ConfigLoader.fileName): \(error)")
      }
    }
    let file: URL
    do {
      file = URL(filePath: try await git.commonDirectory(), directoryHint: .isDirectory)
        .appending(path: StateRootResolver.commonConfigFile, directoryHint: .notDirectory)
    } catch {
      throw BuildLoopError("can't find the git common dir that holds config.toml: \(error)")
    }
    do {
      let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
      return Self(
        profile: .brownfield,
        presets: try TOMLConfigDecoder().decodeBrownfield(text).buildPresets, file: file.path)
    } catch {
      throw BuildLoopError("can't load \(file.path): \(error)")
    }
  }

  /// The preset `name` names, or why this profile can't run it.
  func preset(named name: String) -> Result<BuildPreset, BuildLoopError> {
    switch (profile, name == Self.brownfieldPresetName) {
    case (.brownfield, false):
      return .failure(
        BuildLoopError(
          "preset `\(name)` can't run here: this clone uses the brownfield profile, which runs "
            + "only `--preset \(Self.brownfieldPresetName)` from \(file)"))
    case (.owned, true):
      return .failure(
        BuildLoopError(
          "preset `\(name)` belongs to the brownfield profile, and this repository is owned: "
            + "it commits \(file); pick 1 of its own presets"))
    case (.brownfield, true), (.owned, false):
      guard let preset = presets[name] else {
        let known = presets.keys.sorted().joined(separator: ", ")
        return .failure(
          BuildLoopError(
            "preset `\(name)` isn't defined in \(file); known presets: "
              + (known.isEmpty ? "none" : known)))
      }
      return .success(preset)
    }
  }
}

enum BuildStartRun {
  static func run(
    slug: String, presetName: String, session: String?, presets: [String: BuildPreset],
    git: any Git, clock: any BuildClock, suffix: UInt32
  ) async -> BuildLoopResult<BuildStartReport> {
    await run(
      slug: slug, presetName: presetName, session: session, catalog: .owned(presets), git: git,
      clock: clock, suffix: suffix)
  }

  static func run(
    slug: String, presetName: String, session: String?, catalog: BuildPresetCatalog,
    git: any Git, clock: any BuildClock, suffix: UInt32
  ) async -> BuildLoopResult<BuildStartReport> {
    let command = "build start"
    if let refusal: BuildLoopResult<BuildStartReport> = await BuildLoop.authorize(
      command, slug: slug, session: session, git: git)
    {
      return refusal
    }
    let preset: BuildPreset
    switch catalog.preset(named: presetName) {
    case .success(let found): preset = found
    case .failure(let error): return .blocked(command, slug, error.message)
    }
    do throws(BuildLoopError) {
      let layout = try await BuildLoop.planLayout(slug, git: git)
      let status = try BuildLoop.indexEntry(slug, layout: layout)?.status
      guard status == PlanStatus.planned.rawValue else {
        return .refused(
          command, slug, .red,
          "plan `\(slug)` is \(status.map { "`\($0)`" } ?? "not in the index"); a build starts "
            + "only from `planned`")
      }
      let startedAt = clock.now()
      let timeBox: RunTimeBox?
      switch catalog.profile {
      case .owned: timeBox = nil
      case .brownfield:
        timeBox = try runTimeBox(slug, layout: layout, preset: preset, startedAt: startedAt)
      }
      let store: BuildRunStore
      do {
        store = try await BuildRunStore.create(
          plan: slug, presetName: presetName, preset: preset, startedAt: startedAt, git: git,
          suffix: suffix, timeBox: timeBox)
      } catch {
        return .blocked(command, slug, "creating the build run: \(error)")
      }
      try seedReturns(slug, layout: layout, into: store.layout)
      try await BuildLoop.setIndex(
        slug, .building,
        resume: "build run \(store.runID) (preset \(presetName)) in progress; continue with "
          + "`swiftgate build next \(slug)`",
        git: git)
      return BuildLoopResult(
        command: command, plan: slug, verdict: .green,
        report: BuildStartReport(
          command: command, plan: slug, runId: store.runID, presetName: presetName,
          indexStatus: .building),
        holder: nil, message: "started build run \(store.runID)")
    } catch {
      return .blocked(command, slug, error.message)
    }
  }

  /// A brownfield build's box: the one `swiftgate run` wrote into the plan's `clock.json`,
  /// measured from the launch, or, for a plan no run launched, the preset's from now. A brownfield
  /// build never runs without one.
  private static func runTimeBox(
    _ slug: String, layout: PlanStateLayout, preset: BuildPreset, startedAt: Date
  ) throws(BuildLoopError) -> RunTimeBox {
    let path: String
    do {
      path = try layout.plan(slug).directory + "/" + RunClock.fileName
    } catch {
      throw BuildLoopError("invalid plan name `\(slug)`: \(error)")
    }
    let data: Data
    do {
      data = try Data(contentsOf: URL(filePath: path))
    } catch CocoaError.fileReadNoSuchFile {
      return RunTimeBox(
        startedAt: startedAt,
        limits: TimeBoxLimits.resolve(preset: preset, override: nil).limits)
    } catch {
      throw BuildLoopError("reading \(path) for the run's time box: \(error)")
    }
    let launched: RunClock
    do {
      launched = try RunClock.decode(data)
    } catch {
      throw BuildLoopError("\(path) doesn't decode, so the run's time box is unknown: \(error)")
    }
    return launched.runTimeBox
      ?? RunTimeBox(
        startedAt: launched.started,
        limits: TimeBoxLimits.resolve(preset: preset, override: nil).limits)
  }

  /// Copies the returns `plan import` recorded before any run existed, such as a brownfield
  /// contract's, into the new run's `returns/`, where dependents' packs read their notes.
  private static func seedReturns(
    _ slug: String, layout: PlanStateLayout, into run: BuildRunLayout
  ) throws(BuildLoopError) {
    let files = FileManager.default
    let source: URL
    do {
      source = URL(filePath: try layout.plan(slug).returnsDirectory, directoryHint: .isDirectory)
    } catch {
      throw BuildLoopError("invalid plan name `\(slug)`: \(error)")
    }
    guard files.fileExists(atPath: source.path) else { return }
    let destination = URL(filePath: run.directory, directoryHint: .isDirectory)
      .appending(path: "returns", directoryHint: .isDirectory)
    do {
      let names = try files.contentsOfDirectory(atPath: source.path).filter {
        $0.hasSuffix(".json")
      }
      guard !names.isEmpty else { return }
      try files.createDirectory(at: destination, withIntermediateDirectories: true)
      for name in names.sorted() {
        let data = try Data(contentsOf: source.appending(path: name))
        try data.write(to: destination.appending(path: name), options: .atomic)
      }
    } catch {
      throw BuildLoopError(
        "copying \(source.path) into run \(run.runID)'s returns: \(error); the run is created "
          + "but its dependents can't read those returns")
    }
  }

  static func render(_ result: BuildLoopResult<BuildStartReport>, format: OutputFormat) -> String {
    BuildLoop.render(result, format: format) {
      "build start: run \($0.runId) of plan `\($0.plan)` with preset `\($0.presetName)`; index set "
        + "to building"
    }
  }
}

struct BuildStartCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "start",
    abstract: "Start a claimed plan's build run: write run.json and set the index to building.",
    discussion:
      "The caller must already hold the plan's lock. Prints the run id. Exits 0 when started, 1 "
      + "when --session doesn't hold the lock or the plan's index status isn't planned, and 2 "
      + "for a missing --session, a preset the config doesn't define, a preset from the other "
      + "profile (only `brownfield` in a brownfield clone, never `brownfield` in an owned "
      + "repository), or unreadable plan state.")

  @Argument(help: "The plan's slug.")
  var plan: String

  @Option(help: "The build preset to run.")
  var preset: String

  @Option(help: "The session id holding the plan's lock (from the SessionStart context).")
  var session: String?

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let git = BuildLoop.git()
    let catalog: BuildPresetCatalog
    do {
      catalog = try await BuildPresetCatalog.load(root: root, git: git)
    } catch {
      let result = BuildLoopResult<BuildStartReport>.blocked("build start", plan, error.message)
      Console.write(BuildStartRun.render(result, format: output.format))
      throw ExitCode(result.verdict.exitCode)
    }
    let result = await BuildStartRun.run(
      slug: plan, presetName: preset, session: session, catalog: catalog, git: git,
      clock: LiveBuildClock(), suffix: UInt32.random(in: .min ... .max))
    Console.write(BuildStartRun.render(result, format: output.format))
    try BuildLoop.exit(result)
  }
}

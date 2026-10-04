import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// `swiftgate run <spec.md>`: prepares a brownfield clone (discover, warm-up, plan branch) and
/// starts the orchestrator on the run skill. `run report` closes the run.
struct RunCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "run",
    abstract: "Plan and build a spec in a brownfield clone with no approval step.",
    subcommands: [RunStartCommand.self, RunReportCommand.self],
    defaultSubcommand: RunStartCommand.self)
}

/// Why a run couldn't be prepared or launched.
struct RunStartError: Error, Sendable, Equatable {
  let message: String
}

/// Starts `swiftgate warmup` so that it outlives `run` and the orchestrator session, and nothing
/// waits on it.
protocol WarmupSpawning: Sendable {
  /// Starts the warm-up in `directory`, appending its output to `log`. Returns its pid when known.
  func spawn(directory: URL, log: URL) async throws(RunStartError) -> Int32?
}

/// Starts the orchestrator's `claude` session.
protocol ClaudeLaunching: Sendable {
  /// Runs `claude` with `arguments` in `directory`. The live launcher replaces this process and
  /// so returns only on failure.
  func launch(arguments: [String], directory: URL) throws(RunStartError)
}

/// What `run` prepared before launching the orchestrator.
struct RunPrepared: Sendable, Equatable, Encodable {
  let slug: String
  /// The worktree root `run` was started in.
  let root: String
  let planDirectory: String
  let clock: RunClock
  /// `<common>/swift-harness/settings.json`, which `claude --settings` loads.
  let settings: String
  let warmupLog: String
  let warmupPID: Int32?
  /// Non-gating lines from discovery for stderr.
  let notes: [String]
}

extension RunCommand {
  /// The run's inputs a test replaces.
  struct Dependencies: Sendable {
    var runner: any ProcessRunner = LiveProcessRunner()
    var discover = DiscoverCommand.Dependencies()
    var warmup: any WarmupSpawning = LiveWarmupSpawner()
    var now: @Sendable () -> Date = { Date() }
  }

  /// Starts the clock, copies an untracked spec into the plan dir, applies discovery, starts the
  /// warm-up detached and creates the plan branch at `HEAD`, never moving the checked-out branch.
  static func prepare(
    spec: String, directory: URL, slug: String?, dependencies: Dependencies
  ) async throws(RunStartError) -> RunPrepared {
    throw RunStartError(message: "swiftgate run is not implemented yet")
  }

  /// Starts the orchestrator on the run skill for `prepared`, with `extra` passed to `claude`.
  static func launch(
    _ prepared: RunPrepared, extra: [String], claude: any ClaudeLaunching
  ) throws(RunStartError) {
    throw RunStartError(message: "swiftgate run is not implemented yet")
  }
}

/// Runs `swiftgate warmup` behind a shell that exits at once, so the warm-up is reparented away
/// from the orchestrator and lives in a process group of its own.
struct LiveWarmupSpawner: WarmupSpawning {
  var runner: any ProcessRunner = LiveProcessRunner()
  /// This swiftgate binary.
  var executable: String = Bundle.main.executablePath ?? CommandLine.arguments[0]
  var arguments = ["warmup"]

  func spawn(directory: URL, log: URL) async throws(RunStartError) -> Int32? {
    throw RunStartError(message: "the warm-up spawner is not implemented yet")
  }
}

/// Replaces this process with `claude`, leaving it the terminal's foreground process.
struct ExecClaudeLauncher: ClaudeLaunching {
  func launch(arguments: [String], directory: URL) throws(RunStartError) {
    throw RunStartError(message: "the claude launcher is not implemented yet")
  }
}

/// `swiftgate run [start] <spec.md>`; `start` is the default, so `run <spec.md>` reaches it.
struct RunStartCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "start",
    abstract: "Prepare the clone and launch the orchestrator on a spec.")

  @Argument(help: "The spec to build, read by path; an untracked one is copied to the plan dir.")
  var spec: String

  @Option(help: "The plan slug; defaults to the spec's file name.")
  var slug: String?

  @Flag(help: "Print JSON.")
  var json = false

  @Argument(parsing: .postTerminator, help: "After --, passed to claude unchanged.")
  var claudeArguments: [String] = []

  func run() async throws {
    try StubCommand.notImplemented("run", json: json)
  }
}

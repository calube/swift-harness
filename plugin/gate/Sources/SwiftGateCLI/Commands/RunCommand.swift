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
  /// Stops the warm-up `spawn` started, when the run it was started for never launched.
  func stop(pid: Int32)
}

/// Starts the orchestrator's `claude` session.
protocol ClaudeLaunching: Sendable {
  /// The `claude` executable ``launch(executable:arguments:directory:)`` runs, found before the
  /// run prepares anything.
  func resolve() throws(RunStartError) -> String
  /// Runs `executable` with `arguments` in `directory`. The live launcher replaces this process
  /// and so returns only on failure.
  func launch(executable: String, arguments: [String], directory: URL) throws(RunStartError)
}

/// What `run` prepared before launching the orchestrator.
struct RunPrepared: Sendable, Equatable, Encodable {
  let slug: String
  /// The session id `claude` starts under, which `run` wrote into the plan's lock.
  let session: String
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
    /// The orchestrator's session id, a UUID as `claude --session-id` requires.
    var newSession: @Sendable () -> String = { UUID().uuidString.lowercased() }
  }

  /// Prepares the clone and launches the orchestrator in it. `announce` sees what was prepared
  /// before the launch, which replaces this process.
  static func start(
    spec: String, directory: URL, slug: String?, extra: [String], dependencies: Dependencies,
    claude: any ClaudeLaunching, announce: (RunPrepared) -> Void = { _ in }
  ) async throws(RunStartError) -> RunPrepared {
    let prepared = try await prepare(
      spec: spec, directory: directory, slug: slug, dependencies: dependencies)
    announce(prepared)
    try launch(prepared, extra: extra, claude: claude)
    return prepared
  }

  /// Starts the clock, copies an untracked spec into the plan dir, applies discovery, starts the
  /// warm-up detached and creates the plan branch at `HEAD`, never moving the checked-out branch.
  static func prepare(
    spec: String, directory: URL, slug requested: String?, dependencies: Dependencies
  ) async throws(RunStartError) -> RunPrepared {
    let runner = dependencies.runner
    let tree = GitTrackedTree(runner: runner, directory: directory)
    let root: URL
    let layout: BrownfieldStateLayout
    let base: String
    do {
      root = try await tree.repositoryRoot()
      layout = try await tree.stateLayout()
      base = try await tree.head()
    } catch {
      throw RunStartError(message: error.message)
    }
    let rootPath = root.path(percentEncoded: false)

    let started = dependencies.now()
    let origin = absolute(spec, against: directory)
    let text: Data
    do {
      text = try Data(contentsOf: URL(filePath: origin))
    } catch {
      throw RunStartError(message: "reading the spec \(origin): \(error.localizedDescription)")
    }
    guard !text.isEmpty else { throw RunStartError(message: "the spec \(origin) is empty") }
    let source: RunSpecSource =
      try await git(["ls-files", "--error-unmatch", "--", origin], root: rootPath, runner: runner)
      == nil ? .copied : .tracked

    let slug = try await pickSlug(
      requested, origin: origin, layout: layout, root: rootPath, runner: runner)
    let planBranch = BrownfieldRunReport.planBranch(slug: slug)
    let planDirectory = layout.plan(slug: slug)
    let files = FileManager.default
    do {
      try files.createDirectory(at: planDirectory, withIntermediateDirectories: true)
    } catch {
      throw RunStartError(
        message: "creating the plan dir \(planDirectory.path): \(error.localizedDescription)")
    }

    let clock: RunClock
    let discovered: DiscoverCommand.Outcome
    let warmupLog = layout.worktreeRoot.appending(path: "logs/warmup-\(slug).log")
    let warmupPID: Int32?
    do throws(RunStartError) {
      let read =
        source == .tracked
        ? origin : planDirectory.appending(path: RunClock.specCopyName).path(percentEncoded: false)
      clock = RunClock(
        started: started, spec: read, origin: origin, specSource: source, planBranch: planBranch,
        base: base)
      if source == .copied { try write(text, to: read) }
      try write(try encode(clock), to: planDirectory.appending(path: RunClock.fileName).path)

      do {
        discovered = try await DiscoverCommand.apply(
          directory: root, edits: [], dependencies: dependencies.discover)
      } catch {
        throw RunStartError(message: "discover --apply: \(describe(error))")
      }
      guard files.fileExists(atPath: layout.settings.path) else {
        throw RunStartError(
          message: "\(layout.settings.path) wasn't written, so claude would start with no hooks: "
            + discovered.notes.joined(separator: "; "))
      }
      warmupPID = try await dependencies.warmup.spawn(directory: root, log: warmupLog)
    } catch {
      try? files.removeItem(at: planDirectory)
      throw error
    }

    guard
      try await git(["branch", "--no-track", planBranch, base], root: rootPath, runner: runner)
        != nil
    else {
      throw RunStartError(message: "git branch \(planBranch) \(base) failed")
    }
    return RunPrepared(
      slug: slug, session: dependencies.newSession(), root: rootPath,
      planDirectory: planDirectory.path(percentEncoded: false),
      clock: clock, settings: layout.settings.path(percentEncoded: false),
      warmupLog: warmupLog.path(percentEncoded: false), warmupPID: warmupPID,
      notes: discovered.notes)
  }

  /// Starts the orchestrator on the run skill for `prepared`, with `extra` passed to `claude`.
  static func launch(
    _ prepared: RunPrepared, extra: [String], claude: any ClaudeLaunching
  ) throws(RunStartError) {
    let prompt = RunLaunch.prompt(
      slug: prepared.slug, spec: prepared.clock.spec, planBranch: prepared.clock.planBranch)
    try claude.launch(
      executable: "claude",
      arguments: RunLaunch.arguments(
        settings: prepared.settings, session: prepared.session, prompt: prompt, extra: extra),
      directory: URL(filePath: prepared.root, directoryHint: .isDirectory))
  }

  /// `requested` when it is free and a valid plan name, else a slug from the spec's file name
  /// that no plan dir or `swift-harness/` branch uses yet.
  private static func pickSlug(
    _ requested: String?, origin: String, layout: BrownfieldStateLayout, root: String,
    runner: any ProcessRunner
  ) async throws(RunStartError) -> String {
    let branches = Set(
      (try await git(
        ["for-each-ref", "--format=%(refname:short)", "refs/heads/swift-harness/"], root: root,
        runner: runner) ?? "").split(separator: "\n").map(String.init))
    let taken = { (slug: String) in
      slug.lowercased() == PlanStateLayout.sprintsDirectoryName
        || branches.contains(BrownfieldRunReport.planBranch(slug: slug))
        || FileManager.default.fileExists(atPath: layout.plan(slug: slug).path)
    }
    guard let requested else { return RunSlug.make(specPath: origin, isTaken: taken) }
    guard RunSlug.make(specPath: requested + ".md", isTaken: { _ in false }) == requested else {
      throw RunStartError(
        message: "--slug \(requested) must be lowercase letters and digits joined by dashes")
    }
    guard !taken(requested) else {
      throw RunStartError(message: "--slug \(requested) is taken by a plan dir or branch")
    }
    return requested
  }

  /// `git <arguments>`'s stdout in `root`, or `nil` when it exits non-zero.
  private static func git(_ arguments: [String], root: String, runner: any ProcessRunner)
    async throws(RunStartError) -> String?
  {
    let output: ProcessOutput
    do {
      output = try await runner.run(
        ProcessInvocation(
          executable: "git", arguments: arguments, workingDirectory: root, timeout: .seconds(60)))
    } catch {
      throw RunStartError(message: "git \(arguments.joined(separator: " ")): \(error)")
    }
    return output.status.isSuccess ? output.stdout.text : nil
  }

  private static func absolute(_ path: String, against directory: URL) -> String {
    let url =
      path.hasPrefix("/") ? URL(filePath: path) : directory.appending(path: path)
    return url.standardized.path(percentEncoded: false)
  }

  private static func write(_ data: Data, to path: String) throws(RunStartError) {
    do {
      try data.write(to: URL(filePath: path), options: .atomic)
    } catch {
      throw RunStartError(message: "writing \(path): \(error.localizedDescription)")
    }
  }

  private static func encode(_ clock: RunClock) throws(RunStartError) -> Data {
    do {
      return try clock.encoded()
    } catch {
      throw RunStartError(message: "encoding the clock: \(error)")
    }
  }

  private static func describe(_ error: any Error) -> String {
    switch error {
    case let error as DiscoverEditError: error.message
    case let error as GitTrackedTreeError: error.message
    case let error as BrownfieldConfigWriteError: error.message
    default: String(describing: error)
    }
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
    do {
      try FileManager.default.createDirectory(
        at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
    } catch {
      throw RunStartError(
        message: "creating the warm-up log's directory: \(error.localizedDescription)")
    }
    // A non-interactive shell's background job ignores SIGINT, and nohup covers SIGHUP, so
    // stopping the orchestrator from the terminal leaves the warm-up running to the end.
    let script = #"log="$1"; shift; nohup "$@" </dev/null >>"$log" 2>&1 & echo $!"#
    let output: ProcessOutput
    do {
      output = try await runner.run(
        ProcessInvocation(
          executable: "/bin/sh",
          arguments: ["-c", script, "sh", log.path(percentEncoded: false), executable] + arguments,
          workingDirectory: directory.path(percentEncoded: false), timeout: .seconds(60)))
    } catch {
      throw RunStartError(message: "starting the warm-up: \(error)")
    }
    guard output.status.isSuccess else {
      throw RunStartError(message: "starting the warm-up: \(output.stderr.text)")
    }
    return Int32(output.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  func stop(pid: Int32) {}
}

/// Replaces this process with `claude`, leaving it the terminal's foreground process.
struct ExecClaudeLauncher: ClaudeLaunching {
  /// The `PATH` searched for `claude`.
  var searchPath: String? = ProcessInfo.processInfo.environment["PATH"]

  func resolve() throws(RunStartError) -> String { "claude" }

  func launch(executable: String, arguments: [String], directory: URL) throws(RunStartError) {
    guard FileManager.default.changeCurrentDirectoryPath(directory.path(percentEncoded: false))
    else {
      throw RunStartError(message: "can't enter \(directory.path(percentEncoded: false))")
    }
    let argv = ["claude"] + arguments
    var pointers = argv.map { strdup($0) } + [nil]
    execvp(executable, &pointers)
    throw RunStartError(
      message: "claude could not start: \(String(cString: strerror(errno))); is it on PATH?")
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
    let directory = URL(
      filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    do throws(RunStartError) {
      _ = try await RunCommand.start(
        spec: spec, directory: directory, slug: slug, extra: claudeArguments,
        dependencies: .init(), claude: ExecClaudeLauncher(), announce: announce)
    } catch {
      report("run: \(error.message)")
      throw ExitCode(Verdict.blocked.exitCode)
    }
  }

  private func announce(_ prepared: RunPrepared) {
    for note in prepared.notes { report(note) }
    let pid = prepared.warmupPID.map { "pid \($0)" } ?? "pid unknown"
    report(
      "run: plan \(prepared.slug) in \(prepared.planDirectory); spec \(prepared.clock.spec) "
        + "(\(prepared.clock.specSource.rawValue)); plan branch \(prepared.clock.planBranch) at "
        + "\(prepared.clock.base); warm-up \(pid) logging to \(prepared.warmupLog); session "
        + prepared.session)
    if json {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      encoder.dateEncodingStrategy = .iso8601
      Console.write(String(decoding: (try? encoder.encode(prepared)) ?? Data(), as: UTF8.self))
    }
    fflush(stdout)
  }

  private func report(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
  }
}

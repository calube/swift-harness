import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import Synchronization

/// `swiftgate warmup [--areas a,b]`: runs every area's generate, build and test at the base tree
/// in parallel, filling the caches, the warm-up times and the baseline.
struct WarmupCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "warmup",
    abstract: "Warm every brownfield area's caches and record its times and baseline.")

  @Option(help: "Comma-separated area names; every area when absent.")
  var areas: String?

  @Flag(help: "Print JSON.")
  var json = false

  /// Why the warm-up couldn't start.
  struct SetupError: Error, Sendable, Equatable {
    let message: String
  }

  /// What 1 warm-up did.
  struct Outcome: Sendable {
    /// `git rev-parse HEAD^{tree}`: the base tree every file is named by.
    let tree: String
    let timesFile: String
    let areas: [WarmupAreaResult]
    /// Non-gating lines for stderr: a file not written, an event not recorded.
    let notes: [String]
  }

  /// The run's inputs a test replaces.
  struct Dependencies: Sendable {
    var processRunner: any ProcessRunner = LiveProcessRunner()
    /// `nil` runs each command through `/bin/sh` with ``processRunner``.
    var areaRunner: (any AreaCommandRunning)? = nil
    /// `nil` writes events under the repository's state root.
    var events: (any HarnessEventWriting)? = nil
    /// Per command run: a warm-up is never cut short by the gate budgets.
    var deadline: Duration = .seconds(3600)
  }

  /// The warm-up of `areaNames`, or of every area when `nil`, in the clone holding `directory`.
  static func warm(directory: URL, areaNames: [String]?, dependencies: Dependencies)
    async throws(SetupError) -> Outcome
  {
    let process = dependencies.processRunner
    let tracked = GitTrackedTree(runner: process, directory: directory)
    let root: URL
    let layout: BrownfieldStateLayout
    let snapshot: TrackedTreeSnapshot
    let head: String
    do {
      root = try await tracked.repositoryRoot()
      layout = try await tracked.stateLayout()
      snapshot = try await tracked.snapshot()
      head = try await tracked.head()
    } catch {
      throw SetupError(message: error.message)
    }
    let tree = try await baseTree(root: root, runner: process)
    let config = try loadConfig(root: root, layout: layout)
    let areas = try select(areaNames, from: config.areas)

    let store = WarmupTimesStore(layout: layout)
    let known = store.load(tree: tree)
    let runner =
      dependencies.areaRunner
      ?? LeasedDeviceAreaRunner(
        base: LiveAreaCommandRunner(processRunner: process),
        leases: LiveTestDeviceLeases(runner: process))
    let baseline = BaselineStore(
      layout: layout, runner: runner,
      scratch: LiveScratchWorktrees(
        runner: process, repositoryRoot: root.path(percentEncoded: false),
        directory: layout.scratchDirectory))
    let events = dependencies.events ?? EventWriterFactory.make(root: root, enabled: true)
    let generator = XcodeGenerator(runner: process, repositoryRoot: root, layout: layout)
    let notes = Mutex(known.notes)

    let results = await Warmup.run(
      areas: areas,
      dependencies: Warmup.Dependencies(
        layout: layout, repositoryRoot: root.path(percentEncoded: false), trackedTree: snapshot,
        known: known.file, deadline: dependencies.deadline,
        run: { await runner.run($0) },
        generate: { area, body in
          await generate(area, tree: snapshot, generator: generator, body: body)
        },
        finished: { result in
          var lines: [String] = []
          do {
            lines += try await store.record(area: result.area, result.record, tree: tree)
          } catch {
            lines.append("warmup: \(result.area)'s times not written: \(error)")
          }
          do {
            lines += try await baseline.record(result.baseline, tree: tree).map(\.message)
          } catch {
            lines.append("warmup: \(result.area)'s baseline not written: \(error)")
          }
          do {
            try events.append(
              contentsOf: result.events.map {
                HarnessEvent(
                  eventID: UUID().uuidString, time: Date(), head: head,
                  source: HarnessEventSource(route: nil), payload: .warmupRun($0))
              })
          } catch {
            lines.append("warmup: \(result.area)'s warmup.run events not written: \(error)")
          }
          notes.withLock { $0 += lines }
        }))
    return Outcome(
      tree: tree, timesFile: layout.warmup(tree: tree).path, areas: results,
      notes: notes.withLock { $0 })
  }

  /// A generator's outcome as the warm-up records it.
  static func generation(
    from outcome: XcodeGenerateOutcome<WarmupTreeRun>, milliseconds: Int
  ) -> WarmupGeneration {
    switch outcome {
    case .generated(let generation, let run):
      .generated(milliseconds: Self.milliseconds(generation.elapsed), run: run)
    case .notInstalled(_, let message):
      .notGenerated(milliseconds: milliseconds, outcome: .notInstalled, detail: message)
    case .versionMismatch(let tool, let pinned, let installed):
      .notGenerated(
        milliseconds: milliseconds, outcome: .failed,
        detail:
          "\(pinned.source) pins \(tool.rawValue) \(pinned.version), but \(installed) is installed")
    case .failed(let tool, let status, let output):
      .notGenerated(
        milliseconds: milliseconds, outcome: .failed,
        detail: "\(tool.rawValue) generate ended \(status):\n\(output)")
    case .blocked(let tool, let reason):
      .notGenerated(
        milliseconds: milliseconds, outcome: .failed,
        detail: "\(tool.rawValue) generate couldn't run: \(reason)")
    }
  }

  private static func generate(
    _ area: BrownfieldArea, tree: TrackedTreeSnapshot, generator: XcodeGenerator,
    body: @escaping @Sendable (String) async -> WarmupTreeRun
  ) async -> WarmupGeneration {
    guard let xcode = area.xcode,
      let request = XcodeGenerateRequest(
        xcode: xcode, generatedProjectTracked: Warmup.generatedProjectTracked(xcode, tree: tree))
    else {
      return .notGenerated(
        milliseconds: 0, outcome: .failed,
        detail: "\(area.name) names no generator manifest in [areas.xcode]")
    }
    let started = ContinuousClock.now
    let outcome = await generator.generate(request) { generation in
      await body(generation.tree.path(percentEncoded: false))
    }
    return generation(from: outcome, milliseconds: milliseconds(ContinuousClock.now - started))
  }

  private static func baseTree(root: URL, runner: any ProcessRunner) async throws(SetupError)
    -> String
  {
    let output: ProcessOutput
    do {
      output = try await runner.run(
        ProcessInvocation(
          executable: "git", arguments: ["rev-parse", "--verify", "HEAD^{tree}"],
          workingDirectory: root.path, timeout: .seconds(60)))
    } catch {
      throw SetupError(message: "git rev-parse HEAD^{tree}: \(error)")
    }
    let tree = output.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard output.status.isSuccess, !tree.isEmpty else {
      throw SetupError(message: "git rev-parse HEAD^{tree}: \(output.stderr.text)")
    }
    return tree
  }

  private static func loadConfig(root: URL, layout: BrownfieldStateLayout) throws(SetupError)
    -> BrownfieldConfig
  {
    let loaded: LoadedConfig?
    do {
      loaded = try ConfigLoader().loadProfile(repositoryRoot: root, commonDir: layout.commonDir)
    } catch {
      throw SetupError(message: "\(error)")
    }
    guard case .brownfield(let config)? = loaded else {
      throw SetupError(
        message: "\(layout.config.path) holds no brownfield config; run swiftgate discover --apply")
    }
    return config
  }

  /// Every area for `nil`; a name the config lacks fails naming it and the known ones.
  private static func select(_ names: [String]?, from areas: [BrownfieldArea])
    throws(SetupError) -> [BrownfieldArea]
  {
    guard let names else { return areas }
    let unknown = names.filter { name in !areas.contains { $0.name == name } }
    guard unknown.isEmpty else {
      throw SetupError(
        message: "no area named \(unknown.joined(separator: ", ")); the config has "
          + areas.map(\.name).joined(separator: ", "))
    }
    return areas.filter { names.contains($0.name) }
  }

  private static func milliseconds(_ duration: Duration) -> Int {
    Int(
      duration.components.seconds * 1_000
        + duration.components.attoseconds / 1_000_000_000_000_000)
  }

  func run() async throws {
    let directory = URL(
      filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let names = areas.map {
      $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter {
        !$0.isEmpty
      }
    }
    let outcome: Outcome
    do {
      outcome = try await Self.warm(directory: directory, areaNames: names, dependencies: .init())
    } catch {
      FileHandle.standardError.write(Data("warmup: \(error.message)\n".utf8))
      throw ExitCode(Verdict.blocked.exitCode)
    }
    for note in outcome.notes { FileHandle.standardError.write(Data((note + "\n").utf8)) }
    let runs = outcome.areas.flatMap(\.events)
    if json {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      let report = Report(tree: outcome.tree, times: outcome.timesFile, runs: runs)
      Console.write(String(decoding: try encoder.encode(report), as: UTF8.self))
      return
    }
    var lines = ["warmup at tree \(outcome.tree): \(outcome.timesFile)"]
    for result in outcome.areas {
      for step in result.steps {
        lines.append(
          "\(result.area) \(step.step.rawValue): \(step.outcome.rawValue), \(step.milliseconds) ms, "
            + step.cache.rawValue)
        if step.outcome != .passed, let detail = step.detail {
          lines += detail.split(separator: "\n", omittingEmptySubsequences: false).map {
            "  \($0)"
          }
        }
      }
    }
    Console.write(lines.joined(separator: "\n"))
  }

  /// `--json`: the base tree, the times file, and every `warmup.run` payload.
  private struct Report: Encodable {
    let tree: String
    let times: String
    let runs: [WarmupRunEvent]
  }
}

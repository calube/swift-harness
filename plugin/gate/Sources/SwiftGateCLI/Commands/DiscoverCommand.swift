import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// `swiftgate discover [--apply]`: proposes a brownfield clone's areas from its tracked files, and
/// with `--apply` writes `config.toml` and `settings.json` under the git common dir.
struct DiscoverCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "discover",
    abstract: "Propose a brownfield clone's areas and commands; --apply writes its config.")

  @Flag(help: "Write config.toml, settings.json and the dirty-file list under the common dir.")
  var apply = false

  @Option(
    name: .customLong("set"),
    help: ArgumentHelp(
      "With --apply, set <area>.<step>=<command>; its source becomes orchestrator. Repeatable."))
  var sets: [String] = []

  @Option(
    name: .customLong("drop"),
    help: ArgumentHelp("With --apply, drop <area>.<step>; it becomes missing. Repeatable."))
  var drops: [String] = []

  @Option(help: "Why each --drop drops its step; the report repeats it.")
  var reason: String?

  @Flag(help: "Print JSON.")
  var json = false

  /// What 1 discover did.
  struct Outcome: Sendable {
    let proposal: DiscoverProposal
    let milliseconds: Int
    /// The edits the applied proposal carries; empty without `--apply`.
    let edits: [DiscoverEdit]
    /// The config `--apply` wrote; `nil` without it.
    let configPath: String?
    /// Non-gating lines for stderr: a file not written, an edit no longer applied.
    let notes: [String]
  }

  /// The run's inputs a test replaces.
  struct Dependencies: Sendable {
    var runner: any ProcessRunner = LiveProcessRunner()
    var readers: [any EcosystemReader] = EcosystemReaders.all
    /// The plugin directory holding `hooks/hooks.json`; `nil` outside the shim.
    var harnessRoot: URL? = ProcessInfo.processInfo.environment["SWIFTGATE_HARNESS_ROOT"].map {
      URL(filePath: $0, directoryHint: .isDirectory)
    }
    /// `nil` writes events under the repository's state root.
    var events: (any HarnessEventWriting)? = nil
  }

  /// Proposes from the repository at `directory` and writes nothing.
  static func propose(directory: URL, dependencies: Dependencies) async throws -> Outcome {
    let started = ContinuousClock.now
    let proposal = try await gather(directory: directory, dependencies: dependencies).proposal
    return Outcome(
      proposal: proposal, milliseconds: milliseconds(since: started), edits: [], configPath: nil,
      notes: [])
  }

  /// `discover --apply`: proposes, applies `edits` over the ones the last apply recorded, and
  /// writes `config.toml`, `settings.json`, `discover/dirty.json` and `discover/last.json` under
  /// 1 lock, then emits `discover.run`.
  static func apply(directory: URL, edits: [DiscoverEdit], dependencies: Dependencies)
    async throws -> Outcome
  {
    let started = ContinuousClock.now
    let layout = try await GitTrackedTree(runner: dependencies.runner, directory: directory)
      .stateLayout()
    let writer = BrownfieldConfigWriter(layout: layout)
    // An unlocked read is enough for a cache: a stale or unreadable entry only costs a miss, and
    // the locked read below still refuses a malformed record.
    let cached = (try? writer.readLastDiscover())??.cache
    let gathered = try await gather(
      directory: directory, dependencies: dependencies, cached: cached)
    var notes: [String] = []
    let settings = hookSettings(harnessRoot: dependencies.harnessRoot, notes: &notes)

    var result: DiscoverEditResult?
    try await writer.update {
      config, last throws(BrownfieldConfigWriteError) in
      let applied: DiscoverEditResult
      do throws(DiscoverEditError) {
        applied = try Discover.applying(
          carried: last?.edits ?? [], new: edits, to: gathered.proposal)
      } catch {
        throw .rejected(error.message)
      }
      result = applied
      var files = [
        layout.discoverDirty: try encode(
          DiscoverDirtyFiles(head: applied.proposal.head, paths: applied.proposal.dirty)),
        layout.discoverLast: try encode(
          DiscoverRecord(
            proposal: applied.proposal, edits: applied.applied, cache: gathered.cache)),
      ]
      if let settings { files[layout.settings] = settings }
      return BrownfieldStateWrite(
        config: Discover.config(from: applied.proposal, keeping: config), files: files)
    }
    guard let result else { throw BrownfieldConfigWriteError.rejected("nothing was applied") }
    notes += result.stale.map {
      "discover: the recorded edit \($0.area).\($0.step.rawValue) no longer applies: no area named \($0.area)"
    }

    let elapsed = milliseconds(since: started)
    let events =
      dependencies.events ?? EventWriterFactory.make(root: gathered.root, enabled: true)
    do {
      try events.append(
        HarnessEvent(
          eventID: UUID().uuidString, time: Date(), head: result.proposal.head,
          source: HarnessEventSource(route: nil),
          payload: .discoverRun(
            DiscoverRunEvent(
              proposal: result.proposal, milliseconds: elapsed, edited: result.applied.count))))
    } catch {
      notes.append("discover: discover.run not written: \(error)")
    }
    return Outcome(
      proposal: result.proposal, milliseconds: elapsed, edits: result.applied,
      configPath: layout.config.path, notes: notes)
  }

  /// The tracked tree's proposal, the cache entry it came from or made, and the worktree root.
  /// A `cached` entry whose key still matches the tree is reused without running a reader.
  private static func gather(
    directory: URL, dependencies: Dependencies, cached: DiscoverRecord.Cache? = nil
  ) async throws -> (proposal: DiscoverProposal, cache: DiscoverRecord.Cache, root: URL) {
    let tree = GitTrackedTree(runner: dependencies.runner, directory: directory)
    let root = try await tree.repositoryRoot()
    let head = try await tree.head()
    let dirty = try await tree.dirtyPaths()
    let snapshot = try await tree.snapshot()
    let salt = cacheSalt(readers: dependencies.readers)
    if let cached,
      Discover.cacheKey(tree: snapshot, inputs: cached.inputs, salt: salt) == cached.key
    {
      return (cached.proposal(head: head, dirty: dirty), cached, root)
    }
    let (proposal, inputs) = Discover.proposeRecordingInputs(
      tree: snapshot, head: head, dirty: dirty, readers: dependencies.readers)
    let cache = DiscoverRecord.Cache(
      key: Discover.cacheKey(tree: snapshot, inputs: inputs, salt: salt), inputs: inputs,
      areas: proposal.areas)
    return (proposal, cache, root)
  }

  /// This build of swiftgate and its readers: a rebuilt binary or another reader set may propose
  /// differently from the same files.
  private static func cacheSalt(readers: [any EcosystemReader]) -> String {
    let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
    let attributes = try? FileManager.default.attributesOfItem(atPath: executable)
    let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    let size = (attributes?[.size] as? Int) ?? 0
    let names = readers.map { String(reflecting: type(of: $0)) }.joined(separator: ",")
    return "\(executable)|\(modified)|\(size)|\(names)"
  }

  /// The plugin's hooks as a settings file, or `nil` with a note naming why the clone gets none.
  private static func hookSettings(harnessRoot: URL?, notes: inout [String]) -> Data? {
    guard let harnessRoot else {
      notes.append(
        "discover: settings.json not written: run through the plugin's bin/swiftgate, which names the plugin's hooks"
      )
      return nil
    }
    let hooks = harnessRoot.appending(path: "hooks/hooks.json")
    guard let data = FileManager.default.contents(atPath: hooks.path),
      let settings = HookSettings.render(hooksJSON: data, pluginRoot: harnessRoot.path)
    else {
      notes.append("discover: settings.json not written: \(hooks.path) could not be rendered")
      return nil
    }
    return settings
  }

  private static func encode(_ value: some Encodable) throws(BrownfieldConfigWriteError) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    do {
      return try encoder.encode(value) + Data("\n".utf8)
    } catch {
      throw .io(operation: "encode", path: "discover state", reason: String(describing: error))
    }
  }

  private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
    let elapsed = ContinuousClock.now - start
    return Int(
      elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
  }

  func validate() throws {
    if !apply, !sets.isEmpty || !drops.isEmpty || reason != nil {
      throw ValidationError("--set, --drop and --reason need --apply")
    }
  }

  func run() async throws {
    let directory = URL(
      filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let outcome: Outcome
    do {
      if apply {
        let edits = try DiscoverEdit.parse(sets: sets, drops: drops, reason: reason)
        outcome = try await Self.apply(directory: directory, edits: edits, dependencies: .init())
      } else {
        outcome = try await Self.propose(directory: directory, dependencies: .init())
      }
    } catch {
      let message =
        switch error {
        case let error as DiscoverEditError: error.message
        case let error as GitTrackedTreeError: error.message
        case let error as BrownfieldConfigWriteError: error.message
        default: String(describing: error)
        }
      FileHandle.standardError.write(Data("discover: \(message)\n".utf8))
      throw ExitCode(Verdict.blocked.exitCode)
    }
    for note in outcome.notes { FileHandle.standardError.write(Data((note + "\n").utf8)) }
    if json {
      let report = Report(
        applied: outcome.configPath, ms: outcome.milliseconds,
        proposal: DiscoverRecord(proposal: outcome.proposal, edits: outcome.edits))
      Console.write(String(decoding: try Self.encode(report), as: UTF8.self))
    } else {
      Console.write(
        ProposalTable.render(
          outcome.proposal, milliseconds: outcome.milliseconds, appliedTo: outcome.configPath))
    }
  }

  /// `--json`: the config path `--apply` wrote, or `null`, the time taken, and the proposal in
  /// `last.json`'s shape.
  private struct Report: Encodable {
    let applied: String?
    let ms: Int
    let proposal: DiscoverRecord
  }
}

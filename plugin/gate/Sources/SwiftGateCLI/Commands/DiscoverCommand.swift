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

  /// Proposes from the repository at `directory` and prints nothing; `nil` edits means no
  /// `--apply`.
  static func propose(directory: URL, dependencies: Dependencies) async throws -> Outcome {
    Outcome(
      proposal: DiscoverProposal(head: "", areas: [], dirty: []), milliseconds: 0, edits: [],
      configPath: nil, notes: [])
  }

  /// `discover --apply`: proposes, applies `edits` over the ones the last apply recorded, and
  /// writes `config.toml`, `settings.json`, `discover/dirty.json` and `discover/last.json` under
  /// 1 lock, then emits `discover.run`.
  static func apply(directory: URL, edits: [DiscoverEdit], dependencies: Dependencies)
    async throws -> Outcome
  {
    try await propose(directory: directory, dependencies: dependencies)
  }

  func run() async throws {
    try StubCommand.notImplemented("discover", json: json)
  }
}

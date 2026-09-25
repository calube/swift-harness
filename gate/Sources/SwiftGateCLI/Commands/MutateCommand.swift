import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

extension MutateCheck {
  /// `mutate` as its own command, reported as the T1 tier.
  static func command(
    root: URL, swiftPM: any SwiftPM, environment: Environment, base: String,
    context: GateRun.Context
  ) async throws -> GateRunParts {
    let repository: ConfiguredRepository.Loaded
    switch await ConfiguredRepository.load(root: root, swiftPM: swiftPM, command: "mutate") {
    case .failed(let outcome): return try TestCheck.parts(t1Failure: outcome)
    case .loaded(let loaded): repository = loaded
    }
    let (judgement, milliseconds) = await GateRun.timed {
      await run(
        environment, graph: repository.graph, config: repository.config, base: base,
        context: context)
    }
    return GateRunParts(
      tiers: [
        try TierResult(
          tier: .t1, verdict: judgement.verdict, durationMilliseconds: milliseconds,
          testCounts: nil)
      ],
      findings: judgement.findings)
  }
}

struct MutateCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "mutate",
    abstract: "Mutation testing on the Core, client and Live lines changed since the merge base.",
    discussion: """
      Mutates added lines (negate conditional, relational boundary, return default, remove call, \
      remove effect/send) and runs the T1 test targets depending on each mutated module in \
      parallel scratch git worktrees. Any surviving mutant is RED unless its line carries \
      `// swiftgate:equivalent-mutant — <reason>`. Beyond [mutation] max_mutants the mutants are \
      sampled, seeded by the diff so a rerun judges the same ones.
      """)

  @Option(help: "Changes are measured from the merge base of HEAD and this ref.")
  var base = "origin/main"

  @Option(help: "Scratch worktrees running mutants at once (default: CPU cores − 1).")
  var jobs: Int?

  @OptionGroup var output: OutputOptions

  func validate() throws {
    if let jobs, jobs < 1 { throw ValidationError("--jobs must be at least 1") }
  }

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let git = LiveGit(runner: LiveProcessRunner(), repositoryRoot: root.path)
    let environment = MutateCheck.Environment.live(root: root, git: git, workers: jobs)
    try await GateRun.execute(root: root, format: output.format, command: "mutate") { context in
      try await MutateCheck.command(
        root: root, swiftPM: ScopeResolution.liveSwiftPM(root: root), environment: environment,
        base: base, context: context)
    }
  }
}

import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

extension ChangedTestChecks {
  /// Runs one changed-test check as its own command, reported as the T1 tier.
  static func command(
    root: URL, environment: Environment, name: String, context: GateRun.Context,
    check: (ModuleGraph) async -> ChangedTestJudgement
  ) async throws -> GateRunParts {
    let repository: ConfiguredRepository.Loaded
    switch await ConfiguredRepository.load(root: root, swiftPM: environment.swiftPM, command: name)
    {
    case .failed(let outcome): return try TestCheck.parts(t1Failure: outcome)
    case .loaded(let loaded): repository = loaded
    }
    let (judgement, milliseconds) = await GateRun.timed { await check(repository.graph) }
    return GateRunParts(
      tiers: [
        try TierResult(
          tier: .t1, verdict: judgement.verdict, durationMilliseconds: milliseconds,
          testCounts: nil)
      ],
      findings: judgement.findings)
  }
}

struct ProveCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "prove",
    abstract: "Red/green proof: new and changed host tests must fail with the source reverted.",
    discussion: """
      Runs the host tests added or edited since the merge base on the change, then in a scratch \
      git worktree where production source is restored to the merge base (tests, manifests and \
      resources keep the change). Each test must pass on the change and fail on an assertion \
      when reverted; failing only to compile is reported as not proven (compile-only). A test \
      that only fails to compile is tried again at each --proof-base, an ancestor of HEAD where \
      the API it calls exists without its behavior, and is proven if it fails there on an \
      assertion.
      """)

  @Option(help: "Changes are measured from the merge base of HEAD and this ref.")
  var base = "origin/main"

  @Option(
    name: .customLong("proof-base"),
    help: "An ancestor of HEAD to retry compile-only tests at. Repeatable, oldest first.")
  var proofBases: [String] = []

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let environment = ChangedTestChecks.Environment.live(root: root)
    try await GateRun.execute(
      root: root, format: output.format, command: "prove",
      proofBases: proofBases.isEmpty ? nil : proofBases
    ) { context in
      try await ChangedTestChecks.command(
        root: root, environment: environment, name: "prove", context: context
      ) { graph in
        await ChangedTestChecks.prove(
          environment, graph: graph, base: base, proofBases: proofBases, context: context)
      }
    }
  }
}

struct StressCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "stress",
    abstract: "Run new and changed host tests N times; any failing run is RED.")

  @Option(name: .customLong("n"), help: "How many times to run each test.")
  var iterations = ChangedTestChecks.readyStressIterations

  @Option(help: "Changes are measured from the merge base of HEAD and this ref.")
  var base = "origin/main"

  @OptionGroup var output: OutputOptions

  func validate() throws {
    guard iterations >= 1 else { throw ValidationError("--n must be at least 1") }
  }

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let environment = ChangedTestChecks.Environment.live(root: root)
    try await GateRun.execute(root: root, format: output.format, command: "stress") { context in
      try await ChangedTestChecks.command(
        root: root, environment: environment, name: "stress", context: context
      ) { graph in
        await ChangedTestChecks.stress(
          environment, graph: graph, base: base, iterations: iterations, context: context)
      }
    }
  }
}

struct ReachCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "reach",
    abstract: "Run each new or changed host test alone with coverage; it must reach its module.")

  @Option(help: "Changes are measured from the merge base of HEAD and this ref.")
  var base = "origin/main"

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let environment = ChangedTestChecks.Environment.live(root: root)
    try await GateRun.execute(root: root, format: output.format, command: "reach") { context in
      try await ChangedTestChecks.command(
        root: root, environment: environment, name: "reach", context: context
      ) { graph in
        await ChangedTestChecks.reach(environment, graph: graph, base: base, context: context)
      }
    }
  }
}

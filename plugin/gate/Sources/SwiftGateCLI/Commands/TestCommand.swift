import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// Loads what every test-running command needs: the config (required) and the module graph.
enum ConfiguredRepository {
  struct Loaded: Sendable {
    let config: Config
    let graph: ModuleGraph
  }

  enum Result: Sendable {
    case loaded(Loaded)
    case failed(StaticCheckOutcome)
  }

  static func load(root: URL, swiftPM: any SwiftPM, command: String) async -> Result {
    let config: Config
    switch StaticCheckInputs.loadConfig(root: root) {
    case .failure(let failure): return .failed(failure.outcome)
    case .success(nil):
      return .failed(
        .invalid(
          reason:
            "\(command) needs a \(ConfigLoader.fileName) naming the packages to test; "
            + "run the bootstrap or add one"))
    case .success(let loaded?): config = loaded
    }
    switch await ScopeResolution.resolve(config: config, root: root, swiftPM: swiftPM) {
    case .failed(let outcome): return .failed(outcome)
    case .resolved(let scopes):
      guard let graph = scopes.graph else {
        return .failed(.blocked(reason: "module graph unavailable"))
      }
      return .loaded(Loaded(config: config, graph: graph))
    }
  }
}

enum TestCheck {
  /// - Parameter affectedSince: limit to packages affected by changes since this ref; `nil` runs
  ///   every T1 target.
  static func run(
    root: URL, swiftPM: any SwiftPM, git: any Git, affectedSince: String?,
    xcodebuild: any Xcodebuild, context: GateRun.Context
  ) async throws -> GateRunParts {
    let repository: ConfiguredRepository.Loaded
    switch await ConfiguredRepository.load(root: root, swiftPM: swiftPM, command: "test") {
    case .failed(let outcome): return try parts(t1Failure: outcome)
    case .loaded(let loaded): repository = loaded
    }
    if let blocked = try await XcodePinCheck.blockedParts(
      tier: .t1, pin: repository.config.xcode, xcodebuild: xcodebuild)
    {
      return blocked
    }
    let plan: TierPlan
    if let affectedSince {
      do throws(GitError) {
        plan = TierPlan(
          changedPaths: try await ChangedPaths.since(affectedSince, git: git),
          graph: repository.graph, tier: .t1)
      } catch {
        return try parts(t1Failure: .blocked(reason: "git: \(error)"))
      }
    } else {
      plan = TierPlan(allOf: repository.graph, tier: .t1)
    }
    let result = try await HostTestCheck.run(
      HostTestCheck.selections(plan: plan, graph: repository.graph), root: root,
      swiftPM: swiftPM, context: context, readCoverage: false)
    return GateRunParts(tiers: [result.tier], findings: result.findings)
  }

  /// A T1 tier that could not start, reported the way T0 checks report the same failure.
  static func parts(t1Failure outcome: StaticCheckOutcome) throws -> GateRunParts {
    let report = try StaticCheckReport.make(runID: "-", durationMilliseconds: 0, outcome: outcome)
    let tier = try TierResult(
      tier: .t1, verdict: report.verdict, durationMilliseconds: 0, testCounts: nil)
    return GateRunParts(tiers: [tier], findings: report.findings)
  }
}

struct TestCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "test",
    abstract: "Run a test tier and judge it from the test reports, not the exit code.")

  enum TierOption: String, ExpressibleByArgument, CaseIterable {
    case t1, t2, t3
  }

  @Option(
    help: "Tier to run: t1 (host swift test), t2 (simulator tests), t3 (app UI flows).")
  var tier: TierOption

  @Option(help: "Only packages affected by changes since this ref (committed or not).")
  var affectedSince: String?

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let git = LiveGit(runner: LiveProcessRunner(), repositoryRoot: root.path)
    let swiftPM = ScopeResolution.liveSwiftPM(root: root)
    let xcodebuild = LiveXcodebuild(runner: LiveProcessRunner())
    try await GateRun.execute(
      root: root, format: output.format, command: "test \(tier.rawValue)"
    ) { context in
      switch tier {
      case .t1:
        try await TestCheck.run(
          root: root, swiftPM: swiftPM, git: git, affectedSince: affectedSince,
          xcodebuild: xcodebuild, context: context)
      case .t2, .t3:
        try await TestCheck.runSimulator(
          tier: tier == .t2 ? .t2 : .t3, root: root, swiftPM: swiftPM, git: git,
          affectedSince: affectedSince, dependencies: .live(), context: context)
      }
    }
  }
}

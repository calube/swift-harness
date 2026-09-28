import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// Gathers ``DoctorFacts`` from the machine and the repository, then judges them.
enum DoctorRun {
  static let shimPath = ".local/bin/swiftgate"

  /// - Parameter sessionID: the session whose plugin record doctor judges; `nil` judges the
  ///   newest record.
  static func run(
    root: URL, sessionID: String?, swiftPM: any SwiftPM, runner: any ProcessRunner
  ) async throws -> GateRunParts {
    let (result, milliseconds) = try await GateRun.timed { () async throws -> DoctorResult in
      let config: Config
      switch StaticCheckInputs.loadConfig(root: root) {
      case .failure(let failure): return try single(failure.outcome)
      case .success(nil):
        return try single(
          .invalid(reason: "doctor needs a \(ConfigLoader.fileName) naming the Xcode pin"))
      case .success(let loaded?): config = loaded
      }
      return Doctor.evaluate(
        await facts(
          root: root, config: config, sessionID: sessionID, swiftPM: swiftPM, runner: runner))
    }
    let tier = try TierResult(
      tier: .t0, verdict: result.verdict, durationMilliseconds: milliseconds, testCounts: nil)
    return GateRunParts(tiers: [tier], findings: result.findings)
  }

  private static func facts(
    root: URL, config: Config, sessionID: String?, swiftPM: any SwiftPM,
    runner: any ProcessRunner
  ) async -> DoctorFacts {
    async let xcode = try? LiveXcodebuild(runner: runner).version()
    async let swift = output(runner, ["swift", "--version"])
    async let devices = listDevices(runner)
    async let repository = repositoryFacts(root: root, config: config, swiftPM: swiftPM)
    let environment = ProcessInfo.processInfo.environment
    let home = environment["HOME"] ?? NSHomeDirectory()
    let (packages, architecture) = await repository
    return DoctorFacts(
      config: config, xcodeVersionOutput: await xcode, swiftVersionOutput: await swift,
      devices: await devices, freeBytes: HarnessFiles.freeBytes(at: root),
      shim: HarnessFiles.shimStatus(
        linkPath: "\(home)/\(shimPath)", harnessRoot: environment["SWIFTGATE_HARNESS_ROOT"]),
      swiftLintInstalled: HarnessFiles.isOnPath("swiftlint", path: environment["PATH"] ?? ""),
      packages: packages,
      resolvedVersions: HarnessFiles.resolvedVersions(
        root: root, packageDirectories: packages.map(\.path)),
      architectureFindings: architecture,
      mermaidCLIInstalled: HarnessFiles.isOnPath("mmdc", path: environment["PATH"] ?? ""),
      pluginSession: pluginSession(root: root, sessionID: sessionID))
  }

  /// `sessionID`'s record, or else the newest, and the tree at its `pluginRoot` now. With an id,
  /// only that session's file counts: another session's record says nothing about this one.
  private static func pluginSession(root: URL, sessionID: String?) -> PluginSessionFacts {
    let store = SessionRecordStore(worktreeRoot: root)
    let record: SessionRecord?
    var unreadable: [UnreadableSessionRecord] = []
    if let sessionID {
      do {
        record = try store.record(sessionID: sessionID)
      } catch {
        record = nil
        let path =
          (try? store.file(sessionID: sessionID).path) ?? SessionRecordStore.directory
        unreadable.append(UnreadableSessionRecord(path: path, reason: error.description))
      }
    } else {
      let scan = store.scan()
      record = scan.newest
      unreadable = scan.unreadable.map { UnreadableSessionRecord(path: $0.path, reason: $0.reason) }
    }
    return PluginSessionFacts(
      sessionID: sessionID, recorded: record.map { recorded($0) }, unreadable: unreadable,
      directory: SessionRecordStore.directory)
  }

  private static func recorded(_ record: SessionRecord) -> RecordedPluginSession {
    let root = URL(filePath: record.pluginRoot, directoryHint: .isDirectory)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return RecordedPluginSession(record: record, current: .rootMissing) }
    do {
      let tree = try PluginTree.read(root: root)
      return RecordedPluginSession(
        record: record, current: .tree(version: tree.version, hash: tree.hash))
    } catch {
      return RecordedPluginSession(record: record, current: .unreadable(reason: error.description))
    }
  }

  /// The package manifests and the architecture findings doctor repeats. A graph that cannot be
  /// loaded is itself reported.
  private static func repositoryFacts(root: URL, config: Config, swiftPM: any SwiftPM) async
    -> ([PackageManifest], [Finding])
  {
    let graph: ModuleGraph
    switch await ScopeResolution.resolve(config: config, root: root, swiftPM: swiftPM) {
    case .failed(let outcome):
      let report = try? StaticCheckReport.make(
        runID: "-", durationMilliseconds: 0, outcome: outcome)
      return ([], report?.findings ?? [])
    case .resolved(let scopes):
      guard let resolved = scopes.graph else { return ([], []) }
      graph = resolved
    }
    switch await ArchCheck.loadSettings(graph: graph, swiftPM: swiftPM) {
    case .failure(let failure):
      let finding = try? Finding(
        ruleID: StaticCheckReport.environmentRuleID, severity: .minor, file: ".", line: nil,
        message: failure.reason, failureScenario: nil)
      return (graph.packages, finding.map { [$0] } ?? [])
    case .success(let settings):
      let findings =
        (try? ArchitectureRules.evaluate(
          ArchitectureInput(graph: graph, config: config, settings: settings))) ?? []
      return (
        graph.packages,
        findings.filter { $0.ruleID == ArchitectureRules.coreMainActorIsolation.id }
      )
    }
  }

  private static func listDevices(_ runner: any ProcessRunner) async
    -> Result<[SimulatorDevice], ProbeFailure>
  {
    do throws(SimctlError) {
      return .success(try await LiveSimctl(runner: runner).devices())
    } catch {
      return .failure(ProbeFailure(error.message))
    }
  }

  private static func output(_ runner: any ProcessRunner, _ arguments: [String]) async -> String? {
    let result = try? await runner.run(
      ProcessInvocation(executable: "/usr/bin/xcrun", arguments: arguments, timeout: .seconds(60)))
    guard let result, result.status.isSuccess else { return nil }
    // `swift --version` prints to stdout on 6.2 but has used stderr before.
    return result.stdout.text + result.stderr.text
  }

  private static func single(_ outcome: StaticCheckOutcome) throws -> DoctorResult {
    let report = try StaticCheckReport.make(runID: "-", durationMilliseconds: 0, outcome: outcome)
    return DoctorResult(verdict: report.verdict, findings: report.findings)
  }
}

struct DoctorCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "doctor",
    abstract:
      "Check the machine and repository: Xcode pin, toolchain, simulator runtime, disk, shim, "
      + "and toolchain-incompatible dependencies.")

  @OptionGroup var output: OutputOptions

  @Option(
    help: ArgumentHelp(
      "Check this session's plugin record, not the newest one; the SessionStart context's "
        + "`Session id:` line."))
  var session: String?

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    try await GateRun.execute(root: root, format: output.format, command: "doctor") { _ in
      try await DoctorRun.run(
        root: root, sessionID: session, swiftPM: ScopeResolution.liveSwiftPM(root: root),
        runner: LiveProcessRunner())
    }
  }
}

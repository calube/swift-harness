import ArgumentParser
import Darwin
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// Starts a QA run: holds a simulator for it, builds and installs the app, and opens it in the
/// scenario through `agent-device`.
struct SimUpCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "up",
    abstract:
      "Hold a simulator, build and install the app scheme, and open it in a scenario for a QA run.")

  @Option(help: "A [[scenarios]] name to launch the app in; live dependencies when omitted.")
  var scenario: String?

  @Flag(help: "Print the result as JSON.")
  var json = false

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let config: Config
    do {
      guard let loaded = try ConfigLoader().load(repositoryRoot: root) else {
        try finish(
          .failure(
            SimUpFailure(
              rule: .environment, message: "no \(ConfigLoader.fileName) in \(root.path)")))
        return
      }
      config = loaded
    } catch let error as ConfigLoadError {
      print("sim up: \(error)")
      throw ExitCode(error.verdict.exitCode)
    }
    let runID = RunID.make(startedAt: Date(), suffix: UInt32.random(in: .min ... .max))
    let runner = LiveProcessRunner()
    let maxConcurrent = config.simulator.maxConcurrent
    let dependencies = SimUp.Dependencies(
      agentDevice: LiveAgentDevice(runner: runner),
      leases: SimLeaseStore(directory: SimLeaseStore.defaultDirectory()),
      launcher: DetachedLauncher(), xcodebuild: LiveXcodebuild(runner: runner),
      simctl: LiveSimctl(
        runner: runner,
        timeouts: LiveSimctl.Timeouts(quick: .seconds(config.simulator.simctlTimeoutSeconds))),
      bundles: AppBundleReader(), git: LiveGit(runner: runner, repositoryRoot: root.path),
      isAlive: SimulatorClones.processIsAlive, terminate: { _ = kill($0, SIGTERM) },
      slotHolders: {
        SimUp.liveSlotHolders(
          lockDirectory: FileCountingLock.defaultDirectory(), capacity: maxConcurrent)
      }, clock: .continuous(), now: { Date() })
    let request = SimUp.Request(
      worktree: root, config: config, scenario: scenario, runID: runID,
      simDirectory: StateRootResolver.resolve(worktree: root)
        .url(SimSession.directory(runID: runID), directoryHint: .isDirectory),
      derivedDataPath: Self.derivedDataDirectory(root: root).path,
      swiftgateExecutable: Bundle.main.executablePath ?? CommandLine.arguments[0])
    try finish(await SimUp(dependencies: dependencies).run(request))
  }

  private func finish(_ result: Result<SimUpStarted, SimUpFailure>) throws {
    print(Self.output(result, json: json))
    if case .failure(let failure) = result { throw ExitCode(failure.verdict.exitCode) }
  }

  /// This worktree's DerivedData for `sim up` builds, apart from the gate's `app-build` folder so
  /// the two never contend for one build database.
  static func derivedDataDirectory(root: URL) -> URL {
    StateRootResolver.resolve(worktree: root)
      .url(RunLayout.derivedDataDirectory, directoryHint: .isDirectory)
      .appending(path: "sim-up", directoryHint: .isDirectory)
  }

  /// What `sim up` prints for `result`.
  static func output(_ result: Result<SimUpStarted, SimUpFailure>, json: Bool) -> String {
    switch result {
    case .success(let started):
      json ? String(decoding: started.json(), as: UTF8.self) : started.text
    case .failure(let failure):
      json ? String(decoding: failure.json(), as: UTF8.self) : failure.text
    }
  }
}

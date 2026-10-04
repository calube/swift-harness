import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// Records one step of a QA run: the screen and its accessibility tree, as the run's next step.
struct SimSnapCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "snap",
    abstract: "Capture a screenshot and accessibility tree as the next step of a QA run.")

  @Argument(help: "What the step shows, for the step log.")
  var label: String

  @Option(help: "Text the step's tree must hold; sim verify checks it.")
  var assert: String?

  @Argument(help: "The run to capture; this worktree's newest live run when omitted.")
  var runID: String?

  @Flag(help: "Print the result as JSON.")
  var json = false

  func validate() throws {
    guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ValidationError("the step label is empty: name what the step shows")
    }
    if let runID, !SimLease.isValidRunID(runID) {
      throw ValidationError(
        "\"\(runID)\" is not a run id: use letters, digits, '-', '_' and '.', not leading '.'")
    }
  }

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let state = StateRootResolver.resolve(worktree: root)
    let snap = SimSnap(
      dependencies: SimSnap.Dependencies(
        agentDevice: LiveAgentDevice(runner: LiveProcessRunner()),
        leases: SimLeaseStore(directory: SimLeaseStore.defaultDirectory()),
        isAlive: SimulatorClones.processIsAlive, clock: .continuous()))
    let result = await snap.run(
      SimSnap.Request(
        worktree: CanonicalPath.of(root), runID: runID, label: label, assert: assert,
        simDirectory: { state.url(SimSession.directory(runID: $0), directoryHint: .isDirectory) }))
    print(Self.output(result, json: json))
    if case .failure(let failure) = result { throw ExitCode(failure.verdict.exitCode) }
  }

  /// What `sim snap` prints for `result`.
  static func output(_ result: Result<SimSnapped, SimSnapFailure>, json: Bool) -> String {
    switch result {
    case .success(let snapped):
      json ? String(decoding: snapped.json(), as: UTF8.self) : snapped.text
    case .failure(let failure):
      json ? String(decoding: failure.json(), as: UTF8.self) : failure.text
    }
  }
}

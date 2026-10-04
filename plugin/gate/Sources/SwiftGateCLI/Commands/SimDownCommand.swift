import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// Ends a QA run: closes its `agent-device` session, gives its simulator and slot back, and
/// releases `agent-device`'s stale claims on the device.
struct SimDownCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "down",
    abstract: "Close a QA run's session, delete its simulator and free its slot. Idempotent.")

  @Argument(help: "The run to end; this worktree's newest run when omitted.")
  var runID: String?

  @Flag(help: "Print the result as JSON.")
  var json = false

  func validate() throws {
    if let runID, !SimLease.isValidRunID(runID) {
      throw ValidationError(
        "\"\(runID)\" is not a run id: use letters, digits, '-', '_' and '.', not leading '.'")
    }
  }

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let state = StateRootResolver.resolve(worktree: root)
    let down = SimDown.live(runner: LiveProcessRunner())
    let result = await down.run(
      SimDown.Request(
        worktree: CanonicalPath.of(root), runID: runID,
        simDirectory: { state.url(SimSession.directory(runID: $0), directoryHint: .isDirectory) }))
    Console.write(Self.output(result, json: json))
    if case .failure(let failure) = result { throw ExitCode(failure.verdict.exitCode) }
  }

  /// What `sim down` prints for `result`.
  static func output(_ result: Result<SimDowned, SimDownFailure>, json: Bool) -> String {
    switch result {
    case .success(let downed):
      json ? String(decoding: downed.json(), as: UTF8.self) : downed.text
    case .failure(let failure):
      json ? String(decoding: failure.json(), as: UTF8.self) : failure.text
    }
  }
}

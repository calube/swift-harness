import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// Judges a QA run's recorded steps, and records the verdict like any check.
struct SimVerifyCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "verify",
    abstract: "Judge a QA run's recorded steps: GREEN, RED or BLOCKED.")

  @Argument(help: "The run to judge; this worktree's newest live run when omitted.")
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
    let checkoutHead: SimCheckoutHead
    do {
      let sha = try await LiveGit(runner: LiveProcessRunner(), repositoryRoot: root.path)
        .revision("HEAD")
      checkoutHead = sha.map { .commit($0) } ?? .unreadable("HEAD names no commit yet")
    } catch {
      checkoutHead = .unreadable(String(describing: error))
    }
    let verify = SimVerify(
      dependencies: SimVerify.Dependencies(
        leases: SimLeaseStore(directory: SimLeaseStore.defaultDirectory()),
        isAlive: SimulatorClones.processIsAlive, clock: .continuous(), now: { Date() }))
    let result = verify.run(
      SimVerify.Request(
        worktree: CanonicalPath.of(root), runID: runID, checkoutHead: checkoutHead,
        simDirectory: { state.url(SimSession.directory(runID: $0), directoryHint: .isDirectory) },
        historyFile: state.url(RunLayout.historyFile, directoryHint: .notDirectory),
        audit: Self.audit(root: root)))
    if case .success(let verified) = result {
      for line in verified.unrecorded {
        FileHandle.standardError.write(
          Data("swiftgate: could not record sim verify: \(line)\n".utf8))
      }
    }
    Console.write(Self.output(result, json: json))
    let verdict =
      switch result {
      case .success(let verified): verified.report.verdict
      case .failure(let failure): failure.verdict
      }
    if verdict != .green { throw ExitCode(verdict.exitCode) }
  }

  /// The audit scope of a run `sim verify` judges with no flow, in the worktree at `root`.
  static func audit(root: URL) -> SimAuditScope {
    .scope(profile: StateRootResolver.profile(worktree: root), flowSteps: nil)
  }

  /// What `sim verify` prints for `result`.
  static func output(_ result: Result<SimVerified, SimVerifyFailure>, json: Bool) -> String {
    switch result {
    case .success(let verified):
      json ? String(decoding: verified.report.json(), as: UTF8.self) : verified.report.text
    case .failure(let failure):
      json ? String(decoding: failure.json(), as: UTF8.self) : failure.text
    }
  }
}

import ArgumentParser
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
    throw ExitCode(Verdict.blocked.exitCode)
  }

  /// This worktree's DerivedData for `sim up` builds, apart from the gate's `app-build` folder so
  /// the two never contend for one build database.
  static func derivedDataDirectory(root: URL) -> URL {
    root
  }

  /// What `sim up` prints for `result`.
  static func output(_ result: Result<SimUpStarted, SimUpFailure>, json: Bool) -> String {
    ""
  }
}

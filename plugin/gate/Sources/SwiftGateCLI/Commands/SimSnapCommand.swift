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

  func run() async throws {}

  /// What `sim snap` prints for `result`.
  static func output(_ result: Result<SimSnapped, SimSnapFailure>, json: Bool) -> String {
    ""
  }
}

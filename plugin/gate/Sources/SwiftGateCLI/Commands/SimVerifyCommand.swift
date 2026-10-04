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

  func run() async throws {}

  /// What `sim verify` prints for `result`.
  static func output(_ result: Result<SimVerified, SimVerifyFailure>, json: Bool) -> String {
    ""
  }
}

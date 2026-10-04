import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// The detached process `sim up` starts to own a run's simulator until `sim down`, the end of
/// the run's `agent-device` session, or `[qa] session_timeout_minutes`. Not for direct use.
struct SimHoldCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "hold",
    abstract: "Hold one simulator slot and device for a QA run (started by sim up).",
    shouldDisplay: false)

  @Option(name: .customLong("run"), help: "The run id the lease is written under.")
  var runID: String

  func run() async throws {
    try StubCommand.notImplemented("sim hold", json: false)
  }
}

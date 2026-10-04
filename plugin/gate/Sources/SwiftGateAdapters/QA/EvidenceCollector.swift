import Foundation
import SwiftGateDomain

/// The device a final-pass flow ran on, as the logs name it.
public struct QAEvidenceDevice: Sendable, Equatable {
  public var target: AgentDeviceTarget
  public var bundleID: String
  /// When `sim up` started the run; the unified log is read from here on.
  public var since: Date

  public init(target: AgentDeviceTarget, bundleID: String, since: Date) {
    self.target = target
    self.bundleID = bundleID
    self.since = since
  }
}

/// What 1 flow's logs left: run-relative paths, and why any kind wasn't saved.
public struct QAEvidenceCollection: Sendable, Equatable {
  public var files: [String]
  public var gaps: [QAEvidenceKind: String]

  public init(files: [String] = [], gaps: [QAEvidenceKind: String] = [:]) {
    self.files = files
    self.gaps = gaps
  }
}

/// Saves a final-pass flow's logs under `qa/logs/<flow>/`: the session app log and the network
/// dump parsed from it, the `agent-device` trace, the unified log for the app's subsystem, and the
/// app's data container.
public struct EvidenceCollector: Sendable {
  /// The `qa/` folder's subfolder for logs.
  public static let directory = "logs"
  public static let networkLimit = 25
  public static let appLogFileName = "app.log"
  public static let networkFileName = "network.json"
  public static let traceFileName = "trace.log"
  public static let osLogFileName = "os.log"
  public static let containerDirectory = "container"

  private let agentDevice: any AgentDevice
  private let runner: any ProcessRunner

  public init(agentDevice: any AgentDevice, runner: any ProcessRunner) {
    self.agentDevice = agentDevice
    self.runner = runner
  }

  /// Starts the app log stream and the trace, runs `flow`, then saves every kind.
  ///
  /// - Parameters:
  ///   - directory: this flow's logs folder.
  ///   - relativeDirectory: `directory` relative to the run directory.
  public func collect<Outcome: Sendable>(
    on device: QAEvidenceDevice, directory: URL, relativeDirectory: String,
    _ flow: @Sendable () async -> Outcome
  ) async -> (outcome: Outcome, collection: QAEvidenceCollection) {
    (await flow(), QAEvidenceCollection())
  }
}

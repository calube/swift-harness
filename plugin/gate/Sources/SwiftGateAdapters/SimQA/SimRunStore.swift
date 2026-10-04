import Darwin
import Foundation
import SwiftGateDomain

public enum SimRunStoreError: Error, Sendable, Equatable {
  case io(operation: String, path: String, errno: Int32)
  case unreadableSession(path: String, reason: SimSessionDecodingError)
  case unreadableSteps(path: String, reason: SimStepDecodingError)

  public var message: String {
    ""
  }
}

/// A step's screenshot while it is being captured: a dot-prefixed file in `steps/` that no step
/// line names until the store commits it.
public struct SimStepStaging: Sendable, Equatable {
  public var screenshot: URL

  public init(screenshot: URL) {
    self.screenshot = screenshot
  }
}

/// The files of one run's `sim/` folder that `sim snap` reads and writes.
///
/// A step becomes visible all at once: its files are put in place and its line appended while
/// the step log is locked, so two snaps never take one number and a failed snap leaves no line
/// naming a file that isn't there.
public struct SimRunStore: Sendable {
  public let simDirectory: URL

  public init(simDirectory: URL) {
    self.simDirectory = simDirectory
  }

  public var stepLog: URL { simDirectory.appending(path: SimStep.logFileName) }
  public var agentDeviceLog: URL { simDirectory.appending(path: SimSession.logFileName) }

  public func session() throws(SimRunStoreError) -> SimSession {
    throw .io(operation: "read", path: simDirectory.path, errno: ENOENT)
  }

  /// The run's steps in order; none when the log doesn't exist yet.
  public func steps() throws(SimRunStoreError) -> [SimStep] {
    []
  }

  /// Creates `steps/` and names a staging file for the next screenshot.
  public func stage() throws(SimRunStoreError) -> SimStepStaging {
    SimStepStaging(screenshot: simDirectory)
  }

  /// Removes whatever a failed capture left at `staging`.
  public func discard(_ staging: SimStepStaging) {}

  /// Numbers the step after the log's last line, moves the staged screenshot to its `NNN.png`,
  /// writes `treeJSON` unmodified to its `NNN.tree.json`, and appends `makeStep(n)`'s line with
  /// an fsync, all under an exclusive lock on the log. On a throw no line was appended and the
  /// step's files are removed.
  public func commit(
    _ staging: SimStepStaging, treeJSON: Data, makeStep: (Int) -> SimStep
  ) throws(SimRunStoreError) -> SimStep {
    throw .io(operation: "commit", path: stepLog.path, errno: ENOSYS)
  }

  /// Appends `line` to `agent-device.log`; best effort, since the failure it records is already
  /// being reported.
  public func appendLog(_ line: String) {}
}

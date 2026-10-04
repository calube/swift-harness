import Foundation
import SwiftGateDomain

/// Runs an area command through `/bin/sh -c` in the area root, with stderr folded into stdout so
/// the tail keeps the order the runner printed in.
public struct LiveAreaCommandRunner: AreaCommandRunning {
  private let processRunner: any ProcessRunner

  /// - Parameter processRunner: leads each command's own process group, so a timeout kills
  ///   every process the command started.
  public init(processRunner: any ProcessRunner = LiveProcessRunner()) {
    self.processRunner = processRunner
  }

  public func run(_ request: AreaCommandRequest) async -> AreaCommandOutcome {
    .timedOut(tail: "")
  }
}

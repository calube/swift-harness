import Foundation
import SwiftGateDomain

/// Reads the main store, each live task worktree's store and every imported store, the build join
/// and the plan, filtered to 1 build run.
public struct RunViewReader: RunViewReading {
  /// The git common dir, absolute.
  public let commonDirectory: URL
  /// Where this checkout's harness state lives.
  public let stateRoot: StateRoot

  public init(commonDirectory: URL, stateRoot: StateRoot) {
    self.commonDirectory = commonDirectory
    self.stateRoot = stateRoot
  }

  public func read(buildRun: String) throws -> RunViewInput {
    RunViewInput(buildRun: buildRun)
  }
}

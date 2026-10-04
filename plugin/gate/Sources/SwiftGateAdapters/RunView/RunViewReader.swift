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

  /// Until the stores are read, every run reads as damage, so an empty view never passes for a
  /// run with no events.
  public func read(buildRun: String) throws -> RunViewInput {
    RunViewInput(
      buildRun: buildRun,
      damage: [RunView.Damage(source: buildRun, reason: "the run's stores aren't read yet")])
  }
}

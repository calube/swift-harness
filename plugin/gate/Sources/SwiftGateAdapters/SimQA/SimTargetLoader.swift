import Foundation
import SwiftGateDomain

/// Reads the ``SimTarget`` for a worktree from whichever profile its clone runs: the committed
/// `.swiftgate.toml`, or the brownfield `config.toml` under the git common dir.
public enum SimTargetLoader {
  public static func load(worktree: URL) -> Result<SimTarget, SimUpFailure> {
    .failure(SimUpFailure(rule: .environment, message: "unimplemented"))
  }

  /// The settings a holder clones from: `target`'s own iOS version, or else the newest one
  /// `simctl` lists an available ``SimTarget/device`` for.
  public static func simulator(for target: SimTarget, simctl: any Simctl) async
    -> Result<SimulatorConfig, SimUpFailure>
  {
    .failure(SimUpFailure(rule: .environment, message: "unimplemented"))
  }
}

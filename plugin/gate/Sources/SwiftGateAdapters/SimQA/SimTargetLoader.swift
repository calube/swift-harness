import Foundation
import SwiftGateDomain

/// Reads the ``SimTarget`` for a worktree from whichever profile its clone runs: the committed
/// `.swiftgate.toml`, or the brownfield `config.toml` under the git common dir.
public enum SimTargetLoader {
  /// A failure is BLOCKED and names files by their repository-relative names only.
  public static func load(worktree: URL) -> Result<SimTarget, SimUpFailure> {
    let loaded: LoadedConfig?
    do {
      loaded = try ConfigLoader().loadProfile(repositoryRoot: worktree)
    } catch {
      return .failure(environment("the config doesn't load: \(error)"))
    }
    switch loaded {
    case .owned(let config)?:
      return .success(SimTarget(owned: config))
    case .brownfield(let config)?:
      return SimTarget.brownfield(config).mapError { environment($0.message) }
    case nil:
      return .failure(
        environment(
          "no \(Config.fileName) in this worktree and no brownfield "
            + "\(StateRootResolver.commonConfigFile) under its git common dir; an owned "
            + "repository commits \(Config.fileName), and a brownfield clone runs "
            + "swiftgate discover --apply"))
    }
  }

  /// The settings a holder clones from: `target`'s own iOS version, or else the newest one
  /// `simctl` lists an available ``SimTarget/device`` for.
  public static func simulator(for target: SimTarget, simctl: any Simctl) async
    -> Result<SimulatorConfig, SimUpFailure>
  {
    if let os = target.os { return .success(target.simulator(os: os)) }
    let devices: [SimulatorDevice]
    do {
      devices = try await simctl.devices()
    } catch {
      return .failure(SimUpFailure(rule: .noSlot, message: "simctl list failed: \(error)"))
    }
    guard let os = SimulatorSelection.newestOS(device: target.device, in: devices) else {
      return .failure(
        SimUpFailure(
          rule: .noSlot,
          message:
            "no available \"\(target.device)\" simulator on any iOS runtime; create one in "
            + "Xcode or with `xcrun simctl create`"))
    }
    return .success(target.simulator(os: os))
  }

  private static func environment(_ message: String) -> SimUpFailure {
    SimUpFailure(rule: .environment, message: message)
  }
}

/// What `sim up` builds and the simulator it holds for a QA run, read from either profile: an
/// owned repository's `.swiftgate.toml`, or a brownfield clone's `xcode` area.
public struct SimTarget: Sendable, Equatable {
  /// The `.xcworkspace` or `.xcodeproj` the app scheme builds from.
  public enum Container: Sendable, Equatable {
    /// The single workspace or project at the worktree root.
    case worktreeRoot
    /// Repository-relative.
    case project(String)
    /// Repository-relative.
    case workspace(String)
  }

  public let scheme: String
  public let container: Container
  /// The base simulator's name, such as `iPhone 17`.
  public let device: String
  /// The base simulator's iOS version; `nil` takes the newest installed iOS runtime that has an
  /// available ``device``, found when the device is held.
  public let os: String?
  public let maxConcurrent: Int
  public let simctlTimeoutSeconds: Int
  /// Minutes a `sim hold` keeps its device before it releases it unasked.
  public let sessionTimeoutMinutes: Int
  public let scenarios: [Scenario]

  public init(
    scheme: String, container: Container, device: String, os: String?,
    maxConcurrent: Int = SimulatorConfig.defaultMaxConcurrent,
    simctlTimeoutSeconds: Int = SimulatorConfig.defaultSimctlTimeoutSeconds,
    sessionTimeoutMinutes: Int = QAConfig.defaultSessionTimeoutMinutes, scenarios: [Scenario] = []
  ) {
    self.scheme = scheme
    self.container = container
    self.device = device
    self.os = os
    self.maxConcurrent = maxConcurrent
    self.simctlTimeoutSeconds = simctlTimeoutSeconds
    self.sessionTimeoutMinutes = sessionTimeoutMinutes
    self.scenarios = scenarios
  }

  public init(owned config: Config) {
    self.init(
      scheme: config.appScheme, container: .worktreeRoot, device: config.simulator.device,
      os: config.simulator.os, maxConcurrent: config.simulator.maxConcurrent,
      simctlTimeoutSeconds: config.simulator.simctlTimeoutSeconds,
      sessionTimeoutMinutes: config.qa.sessionTimeoutMinutes, scenarios: config.scenarios)
  }

  /// The target of `config`'s 1 `xcode` area.
  public static func brownfield(_ config: BrownfieldConfig) -> Result<SimTarget, SimTargetUnavailable>
  {
    .failure(SimTargetUnavailable(message: "unimplemented"))
  }

  /// The `[simulator]` settings a holder clones from, with ``os`` or the version found for it.
  public func simulator(os resolved: String) -> SimulatorConfig {
    SimulatorConfig(
      device: device, os: os ?? resolved, maxConcurrent: maxConcurrent,
      simctlTimeoutSeconds: simctlTimeoutSeconds)
  }
}

/// Why a brownfield config gives `sim up` nothing to build or run.
public struct SimTargetUnavailable: Error, Sendable, Equatable {
  public let message: String

  public init(message: String) {
    self.message = message
  }
}

extension SimulatorSelection {
  /// The newest iOS version with an available, non-clone device named `device`; `nil` when there
  /// is none.
  public static func newestOS(device: String, in devices: [SimulatorDevice]) -> String? {
    nil
  }
}

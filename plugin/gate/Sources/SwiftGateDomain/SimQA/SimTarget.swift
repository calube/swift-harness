import Foundation

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

  /// The target of `config`'s 1 `xcode` area: its workspace or project, the scheme its `test`
  /// command builds (else its first scheme), and the device that command's `-destination` names.
  /// The simulator limits and the session timeout take their defaults, and no scenario exists.
  public static func brownfield(_ config: BrownfieldConfig) -> Result<
    SimTarget, SimTargetUnavailable
  > {
    let areas = config.areas.filter { $0.xcode != nil }
    guard let area = areas.first, let xcode = area.xcode, areas.count == 1 else {
      let names = config.areas.map { "\($0.name) (\($0.kind.rawValue))" }
      let problem =
        areas.isEmpty
        ? "has no xcode area"
        : "has \(areas.count) xcode areas (\(areas.map(\.name).joined(separator: ", ")))"
      return .failure(
        SimTargetUnavailable(
          message:
            "the brownfield config \(problem), so sim up can't tell which app to build; areas: "
            + (names.isEmpty ? "none" : names.joined(separator: ", "))))
    }
    let container: Container
    if let workspace = xcode.workspace {
      container = .workspace(workspace)
    } else if let project = xcode.project {
      container = .project(project)
    } else {
      return .failure(
        SimTargetUnavailable(message: "xcode area \(area.name) names no workspace or project"))
    }
    let commands = [area.test, area.e2e, area.build].compactMap { $0 }.map(xcodebuildArguments)
    guard
      let scheme = commands.lazy.compactMap({ value(of: "-scheme", in: $0) }).first
        ?? xcode.schemes.first
    else {
      return .failure(
        SimTargetUnavailable(message: "xcode area \(area.name) names no scheme to build"))
    }
    guard let device = commands.lazy.compactMap(simulatorName).first else {
      return .failure(
        SimTargetUnavailable(
          message:
            "xcode area \(area.name) has no command whose -destination names a simulator "
            + "(`name=`), so sim up can't tell which device to hold; set its `test` command's "
            + "-destination with `swiftgate discover --apply --set`"))
    }
    return .success(SimTarget(scheme: scheme, container: container, device: device, os: nil))
  }

  /// The arguments of the first `xcodebuild` in `command`; empty when there is none.
  private static func xcodebuildArguments(_ command: String) -> [String] {
    ShellSyntax.simpleCommands(in: command).first { $0.name == "xcodebuild" }?.arguments ?? []
  }

  private static func value(of option: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1)
    else { return nil }
    return arguments[index + 1]
  }

  /// `iPhone 17` from `-destination 'platform=iOS Simulator,name=iPhone 17'`.
  private static func simulatorName(_ arguments: [String]) -> String? {
    guard let destination = value(of: "-destination", in: arguments),
      destination.contains("Simulator")
    else { return nil }
    return destination.split(separator: ",").lazy
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .first { $0.hasPrefix("name=") }
      .map { String($0.dropFirst("name=".count)) }
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
    let versions = devices.compactMap { candidate -> String? in
      guard candidate.isAvailable, candidate.name == device,
        SimulatorCloneName.ownerPID(of: candidate.name) == nil,
        let runtime = candidate.runtime, runtime.platform == "iOS"
      else { return nil }
      return runtime.version
    }
    return versions.max { components($0).lexicographicallyPrecedes(components($1)) }
  }

  /// `[26, 10]` for `26.10`, so versions order by number rather than by text.
  private static func components(_ version: String) -> [Int] {
    version.split(separator: ".").map { Int($0) ?? 0 }
  }
}

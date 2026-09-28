import Foundation

/// A dotted version compared numerically, missing components counting as zero (`26.2` ==
/// `26.2.0`, `1.9` < `1.24`).
public struct ToolVersion: Sendable, Comparable, CustomStringConvertible {
  public let text: String
  let components: [Int]

  public init(_ text: String) {
    self.text = text
    components = text.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
  }

  public var description: String { text }

  public static func == (lhs: ToolVersion, rhs: ToolVersion) -> Bool {
    compare(lhs, rhs) == 0
  }

  public static func < (lhs: ToolVersion, rhs: ToolVersion) -> Bool {
    compare(lhs, rhs) < 0
  }

  private static func compare(_ lhs: ToolVersion, _ rhs: ToolVersion) -> Int {
    for index in 0..<max(lhs.components.count, rhs.components.count) {
      let left = index < lhs.components.count ? lhs.components[index] : 0
      let right = index < rhs.components.count ? rhs.components[index] : 0
      if left != right { return left < right ? -1 : 1 }
    }
    return 0
  }
}

/// A probe that could not run; its message says why.
public struct ProbeFailure: Error, Sendable, Equatable, ExpressibleByStringLiteral {
  public let message: String

  public init(_ message: String) {
    self.message = message
  }

  public init(stringLiteral value: String) {
    self.init(value)
  }
}

/// Where `~/.local/bin/swiftgate` (the stable path hooks call, spec §4.1) points.
public enum ShimStatus: Sendable, Equatable {
  case current
  /// This binary was not started through the shim, so the expected target is unknown.
  case unverified
  case missing(path: String)
  case dangling(path: String, target: String)
  case elsewhere(path: String, target: String, expected: String)
}

/// Everything `doctor` judges, gathered by adapters.
public struct DoctorFacts: Sendable {
  public let config: Config
  /// `xcodebuild -version`; `nil` or empty when it could not run.
  public let xcodeVersionOutput: String?
  /// `swift --version`.
  public let swiftVersionOutput: String?
  public let devices: Result<[SimulatorDevice], ProbeFailure>
  /// Free bytes on the worktree's volume; `nil` when unreadable.
  public let freeBytes: Int64?
  public let shim: ShimStatus
  public let swiftLintInstalled: Bool
  public let packages: [PackageManifest]
  /// Package identity → resolved version, across the repository's `Package.resolved` files.
  public let resolvedVersions: [String: String]
  /// Architecture findings doctor repeats, such as MainActor default isolation in Core.
  public let architectureFindings: [Finding]
  /// Whether `mmdc`, the Mermaid CLI `design-lint` validates diagrams with, is on `PATH`.
  public let mermaidCLIInstalled: Bool

  public init(
    config: Config, xcodeVersionOutput: String?, swiftVersionOutput: String?,
    devices: Result<[SimulatorDevice], ProbeFailure>, freeBytes: Int64?, shim: ShimStatus,
    swiftLintInstalled: Bool, packages: [PackageManifest], resolvedVersions: [String: String],
    architectureFindings: [Finding], mermaidCLIInstalled: Bool
  ) {
    self.config = config
    self.xcodeVersionOutput = xcodeVersionOutput
    self.swiftVersionOutput = swiftVersionOutput
    self.devices = devices
    self.freeBytes = freeBytes
    self.shim = shim
    self.swiftLintInstalled = swiftLintInstalled
    self.packages = packages
    self.resolvedVersions = resolvedVersions
    self.architectureFindings = architectureFindings
    self.mermaidCLIInstalled = mermaidCLIInstalled
  }
}

public struct DoctorResult: Sendable, Equatable {
  public let verdict: Verdict
  public let findings: [Finding]

  public init(verdict: Verdict, findings: [Finding]) {
    self.verdict = verdict
    self.findings = findings
  }
}

/// A toolchain upgrade that breaks a pinned dependency (spec §6.2 toolchain notes).
public struct UpgradeHazard: Sendable {
  public let xcode: ToolVersion
  public let swift: String
  /// Package identity → the minimum version that builds on that Xcode.
  public let requirements: [(identity: String, minimum: ToolVersion)]
  /// Package identity → a behavior change to audit when that package is in the graph.
  public let notes: [(identity: String, text: String)]
}

/// `swiftgate doctor`: is this machine able to produce evidence, and is the repository set up so
/// the toolchain can build it? Machine problems are BLOCKED, repository problems RED, advisories
/// never change the verdict.
public enum Doctor {
  public static let xcodePinRuleID = "doctor.xcode-pin"
  public static let toolchainRuleID = "doctor.toolchain"
  public static let simulatorRuleID = "doctor.simulator-runtime"
  public static let diskRuleID = "doctor.disk"
  public static let shimRuleID = "doctor.shim"
  public static let swiftLintRuleID = "doctor.swiftlint"
  public static let mermaidCLIRuleID = "doctor.mmdc"
  public static let issueReportingRuleID = "doctor.issue-reporting"
  public static let upgradeHazardRuleID = "doctor.upgrade-hazard"
  public static let profileRuleID = "doctor.profile"

  /// One simulator run's DerivedData plus result bundle runs to several GiB; below this a run is
  /// likely to fail part-way.
  public static let minimumFreeBytes: Int64 = 20 * 1024 * 1024 * 1024

  /// The split `swift-issue-reporting` 2.x package applies from Swift 6.4; before it, Point-Free's
  /// manifests take `IssueReporting` from `xctest-dynamic-overlay` and a direct dependency fails
  /// with a conflicting-target error.
  static let issueReportingSplit = ToolVersion("6.4")

  public static let hazards: [UpgradeHazard] = [
    UpgradeHazard(
      xcode: ToolVersion("26.4"), swift: "6.3",
      requirements: [
        ("swift-composable-architecture", ToolVersion("1.24")),
        ("swift-sharing", ToolVersion("2.8.0")),
      ],
      notes: [
        ("swift-sharing", "rejects writable key paths to @Shared state (TCA #3899/#3900)")
      ]),
    UpgradeHazard(
      xcode: ToolVersion("27"), swift: "6.4",
      requirements: [("swift-composable-architecture", ToolVersion("1.26"))], notes: []),
  ]

  /// `26.2` from `Xcode 26.2\nBuild version 17C48`.
  public static func xcodeVersion(from output: String) -> String? {
    guard let first = output.split(whereSeparator: \.isNewline).first,
      first.hasPrefix("Xcode ")
    else { return nil }
    let version = first.dropFirst("Xcode ".count).trimmingCharacters(in: .whitespaces)
    return version.isEmpty ? nil : version
  }

  /// A pin of `26.2` accepts `26.2` and `26.2.1`, not `26.4`.
  public static func matchesPin(installed: String, pin: String) -> Bool {
    installed == pin || installed.hasPrefix(pin + ".")
  }

  /// `6.2` from `… Apple Swift version 6.2 (swiftlang-…)`.
  public static func swiftVersion(from output: String) -> ToolVersion? {
    guard let range = output.range(of: "Swift version ") else { return nil }
    let version = output[range.upperBound...].prefix { $0.isNumber || $0 == "." }
    return version.isEmpty ? nil : ToolVersion(String(version))
  }

  public static func evaluate(_ facts: DoctorFacts) -> DoctorResult {
    var check = DoctorJudgement()
    let configFile = Config.fileName
    let pin = facts.config.xcode

    switch facts.xcodeVersionOutput.flatMap(xcodeVersion(from:)) {
    case nil:
      check.block(
        xcodePinRuleID, configFile,
        "xcodebuild -version could not be read; is Xcode installed and selected (xcode-select -p)?")
    case let installed? where !matchesPin(installed: installed, pin: pin):
      check.block(
        xcodePinRuleID, configFile,
        "Xcode \(installed) is selected but \(configFile) pins \(pin); select Xcode \(pin) "
          + "(xcode-select -s) or move the pin deliberately")
    default: break
    }

    let toolchain = facts.swiftVersionOutput.flatMap(swiftVersion(from:))
    if toolchain == nil {
      check.block(toolchainRuleID, ".", "swift --version could not be read")
    }

    switch facts.devices {
    case .failure(let failure):
      check.block(simulatorRuleID, configFile, "simulators could not be listed: \(failure.message)")
    case .success(let devices):
      do throws(SimulatorSelectionError) {
        _ = try SimulatorSelection.baseDevice(in: devices, config: facts.config.simulator)
      } catch {
        check.block(simulatorRuleID, configFile, error.message)
      }
    }

    switch facts.freeBytes {
    case nil: check.block(diskRuleID, ".", "free disk space could not be read")
    case let free? where free < minimumFreeBytes:
      check.block(
        diskRuleID, ".",
        "\(gibibytes(free)) GiB free, below the \(gibibytes(minimumFreeBytes)) GiB a simulator "
          + "run needs; run `swiftgate gc` or free space")
    default: break
    }

    switch facts.shim {
    case .current, .unverified: break
    case .missing(let path):
      check.warn(shimRuleID, .minor, "\(path) is missing; hooks call it. Re-run the bootstrap")
    case .dangling(let path, let target):
      check.warn(shimRuleID, .minor, "\(path) points at \(target), which does not exist")
    case .elsewhere(let path, let target, let expected):
      check.warn(
        shimRuleID, .minor,
        "\(path) points at \(target), not this harness (\(expected)); hooks run a different gate")
    }

    if !facts.swiftLintInstalled {
      check.warn(
        swiftLintRuleID, .nit, "SwiftLint is not installed; it is optional and style-only")
    }

    if !facts.mermaidCLIInstalled {
      check.warn(
        mermaidCLIRuleID, .nit,
        "mmdc (the Mermaid CLI) is not on PATH, so design-lint can't validate diagram syntax; "
          + "install it with `npm install -g @mermaid-js/mermaid-cli`")
    }

    if let toolchain, toolchain < issueReportingSplit {
      for package in facts.packages
      where package.remoteDependencies.contains("swift-issue-reporting") {
        check.fail(
          issueReportingRuleID, package.manifestPath,
          "\(package.name) depends on swift-issue-reporting directly; on Swift \(toolchain) "
            + "that conflicts with xctest-dynamic-overlay's IssueReporting. Remove it until "
            + "Swift \(issueReportingSplit)")
      }
    }

    check.findings += facts.architectureFindings

    if let profile = facts.config.profile, facts.config.buildPresets[profile] == nil {
      let defined = facts.config.buildPresets.keys.sorted()
      check.fail(
        profileRuleID, configFile,
        "[harness] profile \"\(profile)\" names no [build.presets.\(profile)] table (defined: "
          + (defined.isEmpty ? "none" : defined.joined(separator: ", "))
          + "); add that preset or name a defined one")
    }

    for hazard in hazards where ToolVersion(pin) < hazard.xcode {
      for (identity, minimum) in hazard.requirements {
        guard let resolved = facts.resolvedVersions[identity],
          ToolVersion(resolved) < minimum
        else { continue }
        check.warn(
          upgradeHazardRuleID, .minor,
          "upgrading to Xcode \(hazard.xcode) (Swift \(hazard.swift)) needs \(identity) ≥ "
            + "\(minimum) (resolved \(resolved))")
      }
      for (identity, text) in hazard.notes where facts.resolvedVersions[identity] != nil {
        check.warn(
          upgradeHazardRuleID, .nit, "Xcode \(hazard.xcode) \(text); audit before upgrading")
      }
    }
    return check.result
  }

  private static func gibibytes(_ bytes: Int64) -> String {
    String(bytes / (1024 * 1024 * 1024))
  }
}

private struct DoctorJudgement {
  var findings: [Finding] = []
  var blocked = false

  var result: DoctorResult {
    let verdict: Verdict =
      findings.contains { $0.severity.failsGate } ? .red : blocked ? .blocked : .green
    return DoctorResult(verdict: verdict, findings: findings)
  }

  mutating func block(_ rule: String, _ file: String, _ message: String) {
    blocked = true
    append(rule, .minor, file, message)
  }

  mutating func fail(_ rule: String, _ file: String, _ message: String) {
    append(rule, .major, file, message)
  }

  mutating func warn(_ rule: String, _ severity: Severity, _ message: String) {
    append(rule, severity, ".", message)
  }

  private mutating func append(
    _ rule: String, _ severity: Severity, _ file: String, _ message: String
  ) {
    // Rule ids, files and messages are never empty, so the report contract cannot reject these.
    if let finding = try? Finding(
      ruleID: rule, severity: severity, file: file, line: nil, message: message,
      failureScenario: nil)
    {
      findings.append(finding)
    }
  }
}

/// `Package.resolved` (versions 2 and 3): identity → version for pins resolved to a version.
public enum ResolvedPins {
  public static func parse(_ data: Data) throws(PackageManifestError) -> [String: String] {
    struct File: Decodable {
      struct Pin: Decodable {
        struct State: Decodable { let version: String? }
        let identity: String
        let state: State
      }
      let pins: [Pin]
    }
    let file: File
    do {
      file = try JSONDecoder().decode(File.self, from: data)
    } catch {
      throw .malformedDescription("Package.resolved: \(error)")
    }
    var versions: [String: String] = [:]
    for pin in file.pins {
      if let version = pin.state.version { versions[pin.identity] = version }
    }
    return versions
  }
}

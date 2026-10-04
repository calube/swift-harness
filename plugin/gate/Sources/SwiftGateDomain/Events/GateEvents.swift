import Foundation

/// 1 timed unit of a gate run. Each case is a place the gate times on its own.
public enum GateStep: String, Sendable, Codable, CaseIterable {
  /// Loading the module graph the scopes come from.
  case resolve
  case lint
  case testlint
  case arch
  case format
  case impact
  /// `swift test` on the host: builds and runs T1.
  case test
  case coverage
  case appBuild = "app-build"
  case reach
  case stress
  case prove
  case mutate
  case judge
  /// `xcodebuild test` on a simulator: T2 or T3.
  case simulator
  /// The push tier's design-evidence, calibration-freshness, docs-lint and prose gates.
  case docs
  case pluginValidate = "plugin-validate"
  /// Writing the run's `report.json` and history line.
  case record
  /// A brownfield area's own `test` command, or its `test_files` narrowed to the changed tests.
  case areaTest = "area-test"
  /// A brownfield area's own `lint` command on the changed files.
  case areaLint = "area-lint"
  /// A brownfield area's own `build` command.
  case areaBuild = "area-build"
  /// The neutral test-quality rules on added lines.
  case neutral
  /// Rerunning a failure at the merge base to see whether the baseline holds it.
  case baseline
  /// Whether each new Swift file is compiled by a target of the Xcode project.
  case xcodeMembership = "xcode-membership"
}

/// Whether a step's build started from a build directory that already existed.
public enum GateDerivedData: String, Sendable, Codable, CaseIterable {
  case warm
  case cold
  /// The step builds nothing.
  case none
}

/// What a step took and decided, as a run collects it before recording.
public struct GateStepTiming: Sendable, Equatable {
  public let step: GateStep
  /// `nil` for a step outside any tier, such as resolving scopes.
  public let tier: Tier?
  public let milliseconds: Int
  public let verdict: Verdict
  public let derivedData: GateDerivedData
  /// The brownfield area the step ran for; `nil` for a step that isn't 1 area's.
  public let area: String?
  /// The step's start, in milliseconds after its gate's start; `nil` when not timed.
  public let startMs: Int?

  public init(
    step: GateStep, tier: Tier?, milliseconds: Int, verdict: Verdict,
    derivedData: GateDerivedData, area: String? = nil, startMs: Int? = nil
  ) {
    self.step = step
    self.tier = tier
    self.milliseconds = milliseconds
    self.verdict = verdict
    self.derivedData = derivedData
    self.area = area
    self.startMs = startMs
  }
}

/// The working tree a run started on. A dirty tree has no tree hash: untracked and modified files
/// can change a verdict without changing `HEAD`, so it never matches another run. Files under a
/// `.harness/` directory are the harness's own state and don't make a tree dirty.
public struct WorkingTreeState: Sendable, Equatable {
  /// `HEAD^{tree}` on a clean tree; `nil` on a dirty one, or before the first commit.
  public let treeHash: String?
  public let dirty: Bool

  public init(treeHash: String?, dirty: Bool) {
    self.treeHash = treeHash
    self.dirty = dirty
  }
}

/// 1 tier of a `gate.run`.
public struct GateRunTier: Sendable, Equatable, Codable {
  public let tier: Tier
  public let verdict: Verdict
  public let milliseconds: Int

  public init(tier: Tier, verdict: Verdict, milliseconds: Int) {
    self.tier = tier
    self.verdict = verdict
    self.milliseconds = milliseconds
  }

  private enum CodingKeys: String, CodingKey {
    case tier, verdict
    case milliseconds = "ms"
  }
}

/// `gate.run`: 1 recorded gate run. Rule ids, counts and repo-relative paths only: a finding's
/// message can quote source, so it never goes in.
public struct GateRunEvent: Sendable, Equatable, Codable {
  /// At most this many finding paths are listed.
  public static let maxFindingPaths = 200

  /// The command that ran, as the history line names it; `nil` when it didn't name itself.
  public let command: String?
  public let verdict: Verdict
  public let milliseconds: Int
  public let treeHash: String?
  /// `nil` when git couldn't say.
  public let dirty: Bool?
  public let tiers: [GateRunTier]
  /// Findings per rule id, every severity.
  public let ruleCounts: [String: Int]
  /// Repo-relative files the findings name, sorted, at most ``maxFindingPaths``.
  public let findingPaths: [String]
  /// Some finding path isn't listed: over the cap, or not a repo-relative path.
  public let findingPathsTruncated: Bool
  /// Waived findings per rule id.
  public let allowanceCounts: [String: Int]
  /// Summed over the tiers that ran tests; `nil` when none did.
  public let testCounts: TestCounts?
  /// Failures a brownfield gate found at both the head and the merge base, so they didn't gate;
  /// `nil` for a run with no baseline.
  public let baselineCount: Int?

  public init(
    command: String?, verdict: Verdict, milliseconds: Int, treeHash: String?, dirty: Bool?,
    tiers: [GateRunTier], ruleCounts: [String: Int], findingPaths: [String],
    findingPathsTruncated: Bool, allowanceCounts: [String: Int], testCounts: TestCounts?,
    baselineCount: Int? = nil
  ) {
    self.command = command
    self.verdict = verdict
    self.milliseconds = milliseconds
    self.treeHash = treeHash
    self.dirty = dirty
    self.tiers = tiers
    self.ruleCounts = ruleCounts
    self.findingPaths = findingPaths
    self.findingPathsTruncated = findingPathsTruncated
    self.allowanceCounts = allowanceCounts
    self.testCounts = testCounts
    self.baselineCount = baselineCount
  }

  /// The event for `report`.
  public init(
    report: RunReport, command: String?, treeHash: String?, dirty: Bool?
  ) throws(ReportContractViolation) {
    var ruleCounts: [String: Int] = [:]
    for finding in report.findings { ruleCounts[finding.ruleID, default: 0] += 1 }
    var allowanceCounts: [String: Int] = [:]
    for allowance in report.allowances {
      allowanceCounts[allowance.ruleID, default: 0] += allowance.count
    }
    // "." names the whole repository, not a file a finding can be joined to.
    let files = Set(report.findings.map(\.file)).subtracting(["."])
    let listable = files.filter(Self.isRepoRelative).sorted()
    let paths = Array(listable.prefix(Self.maxFindingPaths))
    let counted = report.tiers.compactMap(\.testCounts)
    let testCounts: TestCounts? =
      counted.isEmpty
      ? nil
      : try TestCounts(
        passed: counted.reduce(0) { $0 + $1.passed }, failed: counted.reduce(0) { $0 + $1.failed },
        skipped: counted.reduce(0) { $0 + $1.skipped })
    self.init(
      command: command, verdict: report.verdict, milliseconds: report.durationMilliseconds,
      treeHash: treeHash, dirty: dirty,
      tiers: report.tiers.map {
        GateRunTier(tier: $0.tier, verdict: $0.verdict, milliseconds: $0.durationMilliseconds)
      },
      ruleCounts: ruleCounts, findingPaths: paths, findingPathsTruncated: paths.count < files.count,
      allowanceCounts: allowanceCounts, testCounts: testCounts)
  }

  /// A path the payload guard keeps: relative, 1 line, short.
  private static func isRepoRelative(_ path: String) -> Bool {
    !path.hasPrefix("/") && !path.hasPrefix("~") && !path.contains(where: \.isNewline)
      && path.utf8.count < EventPayloadGuard.maxStringBytes
  }

  private enum CodingKeys: String, CodingKey {
    case command, verdict, treeHash, dirty, tiers, ruleCounts, findingPaths
    case findingPathsTruncated, allowanceCounts, testCounts, baselineCount
    case milliseconds = "ms"
  }
}

/// `gate.step`: 1 step of a recorded gate run; its `parentID` is the run's `gate.run`.
public struct GateStepEvent: Sendable, Equatable, Codable {
  public let tier: Tier?
  public let step: GateStep
  public let milliseconds: Int
  public let verdict: Verdict
  public let derivedData: GateDerivedData
  /// The brownfield area the step ran for.
  public let area: String?
  /// The step's start, in milliseconds after its gate's start; `nil` on a line written before
  /// steps were timed from the start, so a reader lays those end to end.
  public let startMs: Int?

  public init(_ timing: GateStepTiming) {
    self.tier = timing.tier
    self.step = timing.step
    self.milliseconds = timing.milliseconds
    self.verdict = timing.verdict
    self.derivedData = timing.derivedData
    self.area = timing.area
    self.startMs = timing.startMs
  }

  private enum CodingKeys: String, CodingKey {
    case tier, step, verdict, derivedData, area, startMs
    case milliseconds = "ms"
  }
}

import Foundation

/// Test tiers: T0 static checks, T1 host unit tests, T2 simulator tests, T3 UI flows.
public enum Tier: String, Sendable, Codable, CaseIterable {
  case t0 = "T0"
  case t1 = "T1"
  case t2 = "T2"
  case t3 = "T3"
}

public struct TestCounts: Sendable, Equatable {
  public let passed: Int
  public let failed: Int
  public let skipped: Int

  public var executed: Int { passed + failed }

  public init(passed: Int, failed: Int, skipped: Int) throws(ReportContractViolation) {
    try requireNonNegative(passed, field: "passed")
    try requireNonNegative(failed, field: "failed")
    try requireNonNegative(skipped, field: "skipped")
    self.passed = passed
    self.failed = failed
    self.skipped = skipped
  }
}

extension TestCounts: Codable {
  private enum CodingKeys: String, CodingKey { case passed, failed, skipped }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      passed: c.decode(Int.self, forKey: .passed),
      failed: c.decode(Int.self, forKey: .failed),
      skipped: c.decode(Int.self, forKey: .skipped))
  }
}

public struct TierResult: Sendable, Equatable {
  public let tier: Tier
  public let verdict: Verdict
  public let durationMilliseconds: Int
  /// `nil` for tiers that run no tests (T0).
  public let testCounts: TestCounts?

  public init(tier: Tier, verdict: Verdict, durationMilliseconds: Int, testCounts: TestCounts?)
    throws(ReportContractViolation)
  {
    try requireNonNegative(durationMilliseconds, field: "durationMilliseconds")
    if verdict == .green, let testCounts, testCounts.failed > 0 {
      throw .greenWithFailedTests(tier, failed: testCounts.failed)
    }
    self.tier = tier
    self.verdict = verdict
    self.durationMilliseconds = durationMilliseconds
    self.testCounts = testCounts
  }
}

extension TierResult: Codable {
  private enum CodingKeys: String, CodingKey {
    case tier, verdict, durationMilliseconds, testCounts
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      tier: c.decode(Tier.self, forKey: .tier),
      verdict: c.decode(Verdict.self, forKey: .verdict),
      durationMilliseconds: c.decode(Int.self, forKey: .durationMilliseconds),
      testCounts: c.decodeIfPresent(TestCounts.self, forKey: .testCounts))
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(tier, forKey: .tier)
    try c.encode(verdict, forKey: .verdict)
    try c.encode(durationMilliseconds, forKey: .durationMilliseconds)
    try c.encode(testCounts, forKey: .testCounts)
  }
}

/// How many findings of one rule a run waived with a justified `swiftgate:allow`. Waivers are
/// counted so a rising number is visible in reports and history rather than silently absorbed.
public struct AllowanceCount: Sendable, Equatable {
  public let ruleID: String
  public let count: Int

  public init(ruleID: String, count: Int) throws(ReportContractViolation) {
    try requireNonEmpty(ruleID, field: "rule")
    if count < 1 { throw .outOfRange(field: "count", value: count) }
    self.ruleID = ruleID
    self.count = count
  }
}

extension AllowanceCount: Codable {
  private enum CodingKeys: String, CodingKey {
    case ruleID = "rule"
    case count
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      ruleID: c.decode(String.self, forKey: .ruleID), count: c.decode(Int.self, forKey: .count))
  }
}

/// The result of one `swiftgate` run: the `--json` output and the unit of run history.
///
/// `verdict` is derived, never stored independently, so it cannot disagree with its parts: it is
/// the merge of every tier's verdict plus `red` if any finding fails the gate.
public struct RunReport: Sendable, Equatable {
  /// Bump on any breaking change to the JSON shape; consumers reject versions they don't know.
  public static let schemaVersion = 1

  public let runID: String
  public let durationMilliseconds: Int
  public let tiers: [TierResult]
  public let findings: [Finding]
  /// Waived findings per rule, sorted by rule id. Waivers never affect the verdict.
  public let allowances: [AllowanceCount]

  public var allowanceTotal: Int { allowances.reduce(0) { $0 + $1.count } }

  public var verdict: Verdict {
    let findingsVerdict: Verdict = findings.contains { $0.severity.failsGate } ? .red : .green
    return Verdict.merged(tiers.map(\.verdict) + [findingsVerdict])
  }

  public init(
    runID: String, durationMilliseconds: Int, tiers: [TierResult], findings: [Finding],
    allowances: [AllowanceCount] = []
  ) throws(ReportContractViolation) {
    try requireNonEmpty(runID, field: "runID")
    try requireNonNegative(durationMilliseconds, field: "durationMilliseconds")
    var seen = Set<Tier>()
    for tier in tiers.map(\.tier) where !seen.insert(tier).inserted {
      throw .duplicateTier(tier)
    }
    var seenRules = Set<String>()
    for ruleID in allowances.map(\.ruleID) where !seenRules.insert(ruleID).inserted {
      throw .duplicateAllowance(ruleID)
    }
    self.allowances = allowances.sorted { $0.ruleID < $1.ruleID }
    self.runID = runID
    self.durationMilliseconds = durationMilliseconds
    self.tiers = tiers
    self.findings = findings
  }
}

extension RunReport: Codable {
  private enum CodingKeys: String, CodingKey {
    case schemaVersion, runID, verdict, durationMilliseconds, tiers, findings, allowances
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let version = try c.decode(Int.self, forKey: .schemaVersion)
    guard version == Self.schemaVersion else {
      throw ReportContractViolation.unsupportedSchemaVersion(version)
    }
    try self.init(
      runID: c.decode(String.self, forKey: .runID),
      durationMilliseconds: c.decode(Int.self, forKey: .durationMilliseconds),
      tiers: c.decode([TierResult].self, forKey: .tiers),
      findings: c.decode([Finding].self, forKey: .findings),
      // Added to v1 additively; reports recorded before it have no waivers to show.
      allowances: c.decodeIfPresent([AllowanceCount].self, forKey: .allowances) ?? [])
    let stored = try c.decode(Verdict.self, forKey: .verdict)
    guard stored == verdict else {
      throw ReportContractViolation.verdictMismatch(stored: stored, derived: verdict)
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(Self.schemaVersion, forKey: .schemaVersion)
    try c.encode(runID, forKey: .runID)
    try c.encode(verdict, forKey: .verdict)
    try c.encode(durationMilliseconds, forKey: .durationMilliseconds)
    try c.encode(tiers, forKey: .tiers)
    try c.encode(findings, forKey: .findings)
    try c.encode(allowances, forKey: .allowances)
  }
}

/// The canonical v1 JSON encoding: sorted keys and fixed formatting so output is byte-stable.
public enum RunReportJSON {
  public static func encode(_ report: RunReport) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(report)
  }

  public static func decode(_ data: Data) throws -> RunReport {
    try JSONDecoder().decode(RunReport.self, from: data)
  }
}

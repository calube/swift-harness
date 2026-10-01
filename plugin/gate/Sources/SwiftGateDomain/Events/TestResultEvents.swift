import CryptoKit
import Foundation

/// How 1 test case ended, as `test.result` records it.
public enum TestResultOutcome: String, Sendable, Codable, CaseIterable {
  case passed
  case failed
  case skipped
  /// A known issue that occurred: `XCTExpectFailure` or `withKnownIssue`.
  case expectedFailure
}

/// 1 test case a gate run's test tier reported, before its record writes it as a `test.result`.
/// It holds no failure message: a message quotes source and values.
public struct TestCaseResult: Sendable, Equatable {
  /// `<target>.<suite>/<name>`, the same for a host and a simulator run of the same test.
  public let test: String
  public let target: String
  public let tier: Tier
  public let outcome: TestResultOutcome
  /// `nil` when the report gave no duration.
  public let milliseconds: Int?

  public init(
    test: String, target: String, tier: Tier, outcome: TestResultOutcome, milliseconds: Int?
  ) {
    self.test = test
    self.target = target
    self.tier = tier
    self.outcome = outcome
    self.milliseconds = milliseconds
  }

  /// A case from a `swift test` xUnit report, whose class name is `<target>.<suite>…`.
  public init(_ testCase: XUnitTestCase, tier: Tier) {
    let parts = testCase.className.split(separator: ".", omittingEmptySubsequences: false)
      .map(String.init)
    let target = parts.first ?? testCase.className
    let outcome: TestResultOutcome =
      switch testCase.outcome {
      case .passed: .passed
      case .failed: .failed
      case .skipped: .skipped
      }
    self.init(
      test: Self.identifier(target: target, suites: Array(parts.dropFirst()), name: testCase.name),
      target: target, tier: tier, outcome: outcome, milliseconds: testCase.milliseconds)
  }

  /// A case from a result bundle, whose identifier is `<suite>…/<name>()`. `nil` for a result
  /// this reader doesn't know, which the tier's own rules already report.
  public init?(_ testCase: XcresultTestCase, tier: Tier) {
    let outcome: TestResultOutcome
    switch testCase.result {
    case .passed: outcome = .passed
    case .failed: outcome = .failed
    case .skipped: outcome = .skipped
    case .expectedFailure: outcome = .expectedFailure
    case .other: return nil
    }
    let parts = testCase.identifier.split(separator: "/", omittingEmptySubsequences: false)
      .map(String.init)
    self.init(
      test: Self.identifier(
        target: testCase.targetName, suites: Array(parts.dropLast()),
        name: parts.last ?? testCase.identifier),
      target: testCase.targetName, tier: tier, outcome: outcome,
      milliseconds: testCase.milliseconds)
  }

  /// Every case in `evidence`'s readable xUnit reports. An unreadable report gives none; the
  /// tier's own rules already report it.
  public static func cases(in evidence: HostTestEvidence) -> [TestCaseResult] {
    [evidence.xctestReport, evidence.swiftTestingReport].compactMap(\.self).flatMap { data in
      ((try? XUnitReport.parse(data)) ?? []).map { TestCaseResult($0, tier: .t1) }
    }
  }

  /// `<target>.<suites joined by />/<name>`, or `<target>.<name>` with no suite. A name's empty
  /// trailing `()` is dropped: an xUnit report names an XCTest method without it, a result bundle
  /// with it.
  public static func identifier(target: String, suites: [String], name: String) -> String {
    let name = name.hasSuffix("()") ? String(name.dropLast(2)) : name
    return "\(target)." + (suites + [name]).joined(separator: "/")
  }
}

/// `test.result`: 1 test case of a recorded gate run; its `parentID` is the run's `gate.run`.
public struct TestResultEvent: Sendable, Equatable, Codable {
  /// The test id, or `sha256:<hex>` of it when the id is too long or not 1 line.
  public let test: String
  /// ``test`` is a hash of the id.
  public let testHashed: Bool
  public let target: String
  public let tier: Tier
  public let outcome: TestResultOutcome
  public let milliseconds: Int?

  public init(_ result: TestCaseResult) {
    // The payload guard would drop the whole event; a hash keeps the result and still joins runs.
    if EventPayloadGuard.rejection(inJSON: result.test) == nil {
      self.test = result.test
      self.testHashed = false
    } else {
      let digest = SHA256.hash(data: Data(result.test.utf8))
      self.test = "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
      self.testHashed = true
    }
    self.target = result.target
    self.tier = result.tier
    self.outcome = result.outcome
    self.milliseconds = result.milliseconds
  }

  private enum CodingKeys: String, CodingKey {
    case test, testHashed, target, tier, outcome
    case milliseconds = "ms"
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    test = try c.decode(String.self, forKey: .test)
    testHashed = try c.decodeIfPresent(Bool.self, forKey: .testHashed) ?? false
    target = try c.decode(String.self, forKey: .target)
    tier = try c.decode(Tier.self, forKey: .tier)
    outcome = try c.decode(TestResultOutcome.self, forKey: .outcome)
    milliseconds = try c.decodeIfPresent(Int.self, forKey: .milliseconds)
  }

  /// `testHashed` is written only when true: most of a store's lines are test results.
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(test, forKey: .test)
    if testHashed { try c.encode(true, forKey: .testHashed) }
    try c.encode(target, forKey: .target)
    try c.encode(tier, forKey: .tier)
    try c.encode(outcome, forKey: .outcome)
    try c.encodeIfPresent(milliseconds, forKey: .milliseconds)
  }
}

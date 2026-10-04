import Foundation

/// What `prove` found for 1 changed test.
public enum ProveResultOutcome: String, Sendable, Codable, CaseIterable {
  /// It failed with the source change reverted.
  case proven
  case passesReverted = "passes-reverted"
  case compileOnly = "compile-only"
  case crashed
  case skipped
}

/// Which assertion form failed first in the reverted run.
public enum ProveAssertionKind: String, Sendable, Codable, CaseIterable {
  case expect
  case require
  case xctAssert = "xct-assert"
  case other
}

/// Where the reverted run first failed: a location and a form, never its source text.
public struct ProveAssertion: Sendable, Equatable, Codable {
  /// Repo-relative.
  public let file: String
  public let line: Int
  public let kind: ProveAssertionKind

  public init(file: String, line: Int, kind: ProveAssertionKind) {
    self.file = file
    self.line = line
    self.kind = kind
  }
}

/// `prove.result`: 1 changed test `prove` ran; its `parentID` is the run's `gate.run`.
public struct ProveResultEvent: Sendable, Equatable, Codable {
  /// The test id, or `sha256:<hex>` of it, as `test.result` spells it.
  public let test: String
  public let testHashed: Bool
  public let target: String
  public let outcome: ProveResultOutcome
  /// The commit `prove` reverted the source to.
  public let proofBase: String?
  public let assertion: ProveAssertion?

  public init(
    test: String, testHashed: Bool, target: String, outcome: ProveResultOutcome,
    proofBase: String?, assertion: ProveAssertion?
  ) {
    self.test = test
    self.testHashed = testHashed
    self.target = target
    self.outcome = outcome
    self.proofBase = proofBase
    self.assertion = assertion
  }

  private enum CodingKeys: String, CodingKey {
    case test, testHashed, target, outcome, proofBase, assertion
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    test = try c.decode(String.self, forKey: .test)
    testHashed = try c.decodeIfPresent(Bool.self, forKey: .testHashed) ?? false
    target = try c.decode(String.self, forKey: .target)
    outcome = try c.decode(ProveResultOutcome.self, forKey: .outcome)
    proofBase = try c.decodeIfPresent(String.self, forKey: .proofBase)
    assertion = try c.decodeIfPresent(ProveAssertion.self, forKey: .assertion)
  }

  /// `testHashed` is written only when true, as `test.result` writes it.
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(test, forKey: .test)
    if testHashed { try c.encode(true, forKey: .testHashed) }
    try c.encode(target, forKey: .target)
    try c.encode(outcome, forKey: .outcome)
    try c.encodeIfPresent(proofBase, forKey: .proofBase)
    try c.encodeIfPresent(assertion, forKey: .assertion)
  }
}

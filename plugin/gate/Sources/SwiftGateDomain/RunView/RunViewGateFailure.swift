import Foundation

extension RunView {
  /// At most this many gating findings ride on 1 gate's failure; the rest count in
  /// ``GateFailure/moreFindings``.
  public static let maxFailureFindings = 10
  /// At most this many failing tests ride on 1 gate's failure; the rest count in
  /// ``GateFailure/moreFailedTests``.
  public static let maxFailedTests = 10
  /// A finding message's cap, under the payload guard's string cap.
  public static let maxFailureMessageBytes = 400

  /// Which gate of a build a gate run was.
  public enum GateStage: String, Sendable, Equatable, Encodable, CaseIterable {
    /// A task's own gate, named in its return.
    case task
    /// A worker's or fixer's own run that no return or ledger event names.
    case worker
    case merge
    case final
  }

  /// 1 gating finding of a gate's report, cut to fit the view.
  public struct FailureFinding: Sendable, Equatable, Encodable {
    public var rule: String
    public var severity: Severity
    /// Repo-relative; `nil` when the finding names the whole repository or a path outside it.
    public var file: String?
    public var line: Int?
    /// 1 line with machine paths taken out, at most ``RunView/maxFailureMessageBytes``.
    public var message: String
    /// The message was cut; the report holds the whole of it.
    public var truncated: Bool

    public init(
      rule: String, severity: Severity, file: String?, line: Int?, message: String,
      truncated: Bool
    ) {
      self.rule = rule
      self.severity = severity
      self.file = file
      self.line = line
      self.message = message
      self.truncated = truncated
    }
  }

  /// 1 test that failed in a gate run, or that `prove` couldn't prove there.
  public struct FailedTest: Sendable, Equatable, Encodable {
    /// As `test.result` spells it.
    public var test: String
    public var tier: Tier?
    /// `nil` for a test that failed; `prove`'s outcome for a changed test it couldn't prove.
    public var proof: ProveResultOutcome?
    /// Where it failed, repo-relative; `nil` when nothing located it.
    public var file: String?
    public var line: Int?

    public init(
      test: String, tier: Tier? = nil, proof: ProveResultOutcome? = nil, file: String? = nil,
      line: Int? = nil
    ) {
      self.test = test
      self.tier = tier
      self.proof = proof
      self.file = file
      self.line = line
    }
  }

  /// Why a gate run wasn't GREEN, bounded so a published report stays small and passes the guard.
  public struct GateFailure: Sendable, Equatable, Encodable {
    /// The `check` tier the run gated at: `push`, or a brownfield `slice`, `merge` or `final`.
    public var checkTier: CheckTier?
    public var stage: GateStage?
    /// The test tiers whose verdict wasn't GREEN, in run order.
    public var tiers: [Tier]
    /// The first ``RunView/maxFailureFindings`` gating findings, in report order.
    public var findings: [FailureFinding]
    public var moreFindings: Int
    /// The first ``RunView/maxFailedTests`` failing tests.
    public var failedTests: [FailedTest]
    public var moreFailedTests: Int
    /// The run's `report.json`, relative to the main checkout; `nil` when it didn't read.
    public var report: String?
    /// The command that lists the run's every event.
    public var command: String

    public init(
      checkTier: CheckTier? = nil, stage: GateStage? = nil, tiers: [Tier] = [],
      findings: [FailureFinding] = [], moreFindings: Int = 0, failedTests: [FailedTest] = [],
      moreFailedTests: Int = 0, report: String? = nil, command: String
    ) {
      self.checkTier = checkTier
      self.stage = stage
      self.tiers = tiers
      self.findings = findings
      self.moreFindings = moreFindings
      self.failedTests = failedTests
      self.moreFailedTests = moreFailedTests
      self.report = report
      self.command = command
    }
  }
}

/// 1 gate run's `report.json`, as the reader found it.
public struct RunViewGateReport: Sendable, Equatable {
  public var report: RunReport
  /// Where it sits, relative to the main checkout.
  public var location: String

  public init(report: RunReport, location: String) {
    self.report = report
    self.location = location
  }
}

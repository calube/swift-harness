import Foundation
import SwiftGateDomain

/// Jev first, then Claude for the blocking questions Jev's answer can't settle (design §13.5).
/// ``JudgeCascade`` decides which questions escalate; this asks the 2 backends and keeps what
/// each said.
public struct CascadingJudge: Judge {
  /// The thresholds of the check that asks, and whether it asks at `ready`.
  public struct Policy: Sendable {
    public let thresholds: JudgeThresholds
    public let atReadyTier: Bool

    public init(thresholds: JudgeThresholds, atReadyTier: Bool) {
      self.thresholds = thresholds
      self.atReadyTier = atReadyTier
    }
  }

  /// 1 subject's cascade: Jev's reply, the plan made from it, and what Claude returned.
  public struct Reply: Sendable {
    public let plan: JudgeCascade.Plan
    public let jev: JudgeReply
    /// `.answered([])` when nothing escalated.
    public let claude: JudgeCascade.ClaudeOutcome
    /// Claude's reply to the escalated questions; `nil` when none escalated or Claude failed.
    public let claudeReply: JudgeReply?
    public let jevIdentity: JudgeIdentity
    public let claudeIdentity: JudgeIdentity

    public init(
      plan: JudgeCascade.Plan, jev: JudgeReply, claude: JudgeCascade.ClaudeOutcome,
      claudeReply: JudgeReply?, jevIdentity: JudgeIdentity, claudeIdentity: JudgeIdentity
    ) {
      self.plan = plan
      self.jev = jev
      self.claude = claude
      self.claudeReply = claudeReply
      self.jevIdentity = jevIdentity
      self.claudeIdentity = claudeIdentity
    }
  }

  public let jev: any Judge
  /// `nil` when no Claude judge is available, so every escalation fails and Jev's answer stays.
  public let claude: (any Judge)?
  /// The set Claude is asked from: the one the Jev set is based on, with its own text.
  public let base: JudgeQuestionSet
  public let policy: Policy

  public init(jev: any Judge, claude: (any Judge)?, base: JudgeQuestionSet, policy: Policy) {
    self.jev = jev
    self.claude = claude
    self.base = base
    self.policy = policy
  }

  public var identity: JudgeIdentity { JudgeIdentity(backend: "", model: "") }

  /// Asks Jev `questions`, then Claude once for every question that escalated. Throws only when
  /// Jev fails; a Claude failure is in the reply.
  public func cascade(_ subject: JudgeSubject, questions: JudgeQuestionSet)
    async throws(JudgeError) -> Reply
  {
    throw .notConfigured("")
  }

  public func answer(_ subject: JudgeSubject, questions: JudgeQuestionSet) async throws(JudgeError)
    -> [JudgeAnswer]
  {
    throw .notConfigured("")
  }

  /// The merged answers, with the usage of both calls summed.
  public func measuredAnswer(_ subject: JudgeSubject, questions: JudgeQuestionSet)
    async throws(JudgeError) -> JudgeReply
  {
    throw .notConfigured("")
  }
}

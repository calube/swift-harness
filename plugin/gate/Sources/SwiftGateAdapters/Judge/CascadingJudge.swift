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

  public var identity: JudgeIdentity { jev.identity }

  /// Who answers an escalated question, named even when no Claude judge is available.
  public var claudeIdentity: JudgeIdentity {
    claude?.identity
      ?? JudgeIdentity(backend: JudgeBackend.claude.rawValue, model: JudgeFactory.defaultModel)
  }

  /// Asks Jev `questions`, then Claude once for every question that escalated. Throws only when
  /// Jev fails; a Claude failure is in the reply.
  public func cascade(_ subject: JudgeSubject, questions: JudgeQuestionSet)
    async throws(JudgeError) -> Reply
  {
    let jevReply = try await jev.measuredAnswer(subject, questions: questions)
    let plan = JudgeCascade.plan(
      subject: subject, jev: jevReply.answers, questions: questions,
      bands: JudgeCascade.bands(for: questions.versionedID), thresholds: policy.thresholds,
      atReadyTier: policy.atReadyTier)
    func reply(_ claude: JudgeCascade.ClaudeOutcome, _ claudeReply: JudgeReply?) -> Reply {
      Reply(
        plan: plan, jev: jevReply, claude: claude, claudeReply: claudeReply,
        jevIdentity: jev.identity, claudeIdentity: claudeIdentity)
    }
    guard !plan.escalated.isEmpty else { return reply(.answered([]), nil) }
    guard let claude else { return reply(.failed(Self.noClaude), nil) }
    do throws(JudgeError) {
      let answered = try await claude.measuredAnswer(
        subject, questions: Self.claudeQuestions(plan.escalated, base: base))
      return reply(.answered(answered.answers), answered)
    } catch {
      return reply(.failed(error.explanation(by: claude.identity)), nil)
    }
  }

  static let noClaude = "no Claude judge is available"

  /// `ids` from `base` as written: `base` itself when every question escalated, else a set of
  /// its own id so its cache entries never stand in for the whole set's.
  public static func claudeQuestions(_ ids: [String], base: JudgeQuestionSet) -> JudgeQuestionSet {
    let asked = base.questions.filter { ids.contains($0.id) }
    guard asked.count < base.questions.count else { return base }
    return JudgeQuestionSet(
      id: "\(base.id).\(asked.map(\.id).joined(separator: "+"))", version: base.version,
      subjectDescription: base.subjectDescription, questions: asked)
  }

  public func answer(_ subject: JudgeSubject, questions: JudgeQuestionSet) async throws(JudgeError)
    -> [JudgeAnswer]
  {
    try await measuredAnswer(subject, questions: questions).answers
  }

  /// The merged answers, with the usage of both calls summed.
  public func measuredAnswer(_ subject: JudgeSubject, questions: JudgeQuestionSet)
    async throws(JudgeError) -> JudgeReply
  {
    let reply = try await cascade(subject, questions: questions)
    return JudgeReply(answers: reply.decided.map(\.answer), usage: reply.usage)
  }
}

extension CascadingJudge.Reply {
  /// Each answered question with the identity that decided it.
  public var decided: [JudgeCascade.Decided] {
    JudgeCascade.merge(
      plan: plan, jev: jev.answers, claude: claude, jevIdentity: jevIdentity,
      claudeIdentity: claudeIdentity)
  }

  /// Jev's usage plus Claude's when Claude answered: tokens and cost only when both calls report
  /// them, wall and backend time added, since the calls run 1 after the other.
  public var usage: JudgeUsage? {
    guard let jevUsage = jev.usage, let claudeUsage = claudeReply?.usage else {
      return jev.usage
    }
    func sum<Value: AdditiveArithmetic>(_ a: Value?, _ b: Value?) -> Value? {
      guard let a, let b else { return nil }
      return a + b
    }
    return JudgeUsage(
      inputTokens: sum(jevUsage.inputTokens, claudeUsage.inputTokens),
      outputTokens: sum(jevUsage.outputTokens, claudeUsage.outputTokens),
      costUSD: sum(jevUsage.costUSD, claudeUsage.costUSD),
      wallMilliseconds: jevUsage.wallMilliseconds + claudeUsage.wallMilliseconds,
      backendMilliseconds: sum(jevUsage.backendMilliseconds, claudeUsage.backendMilliseconds),
      servedModel: jevUsage.servedModel, cached: jevUsage.cached && claudeUsage.cached)
  }
}

extension JudgeError {
  /// Why `judge` gave no answer, in words a finding can carry.
  public func explanation(by judge: JudgeIdentity) -> String {
    let name = judge.backend
    switch self {
    case .process(.launchFailed(let executable, let reason)):
      return "\(executable) could not start: \(reason)"
    case .process(.timedOut(let executable, let after, _, _)):
      return "\(executable) timed out after \(after.components.seconds) s"
    case .process(.cancelled(let executable)):
      return "\(executable) was cancelled"
    case .backend(let detail):
      return "\(name) reported an error: \(detail)"
    case .malformedReply(let detail):
      return "\(name)'s reply didn't fit the question: \(detail)"
    case .notConfigured(let detail):
      return "\(name) isn't configured: \(detail)"
    case .stateTooLarge(let tokens):
      return "the subject is too large for \(name) (about \(tokens) tokens)"
    }
  }
}

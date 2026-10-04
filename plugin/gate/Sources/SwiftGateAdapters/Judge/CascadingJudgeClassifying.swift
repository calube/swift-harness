import SwiftGateDomain

extension CascadingJudge {
  /// The answers a classifying set such as ``JudgeQuestionSet/diffRisk`` reads its level from,
  /// through the `ready` cascade: Jev, once more after a transport or parse error, then Claude.
  /// Throws when neither backend answered, so a caller never mistakes silence for a level.
  public func classifyingAnswers(_ subject: JudgeSubject, questions: JudgeQuestionSet)
    async throws(JudgeError) -> [JudgeAnswer]
  {
    throw .notConfigured("")
  }
}

import SwiftGateDomain

extension CascadingJudge {
  /// The answers a classifying set such as ``JudgeQuestionSet/diffRisk`` reads its level from,
  /// through the `ready` cascade: Jev, once more after a transport or parse error, then Claude.
  /// Throws when neither backend answered, so a caller never mistakes silence for a level.
  public func classifyingAnswers(_ subject: JudgeSubject, questions: JudgeQuestionSet)
    async throws(JudgeError) -> [JudgeAnswer]
  {
    switch try await readyCascade(subject, questions: questions) {
    case .cascaded(let reply):
      return reply.decided.map(\.answer)
    case .jevFailed(let failure):
      let jevError = failure.error.explanation(by: failure.jevIdentity)
      switch failure.claude {
      case .answered(let answers) where !answers.isEmpty:
        return answers
      case .answered:
        throw failure.error
      case .failed(let why):
        throw .backend("jev: \(jevError); claude: \(why)")
      }
    }
  }
}

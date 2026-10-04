import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// The judge a clone's `[judge]` names, asked through the `ready` cascade so silence never reads
/// as an answer.
struct BrownfieldJudge: Sendable {
  /// Asks `questions`; `base` is the set as Claude reads it when Jev escalates or fails.
  typealias Ask =
    @Sendable (_ subject: JudgeSubject, _ questions: JudgeQuestionSet, _ base: JudgeQuestionSet)
    async throws -> [JudgeAnswer]

  let thresholds: JudgeThresholds
  /// The test-quality set as this backend asks it.
  let testQuality: JudgeQuestionSet
  let ask: Ask

  /// Why a clone with no `[judge]` gets no judge answer.
  static let notConfigured = "the clone's config has no [judge] section"

  /// The cascade for `config`; `nil` when `[judge]` is absent or names no backend.
  static func live(_ config: JudgeConfig, root: URL) -> BrownfieldJudge? {
    nil
  }

  /// What the judge makes of a test the assertion table found nothing in.
  func assertion(_ candidate: AssertionCandidate, source: String) async
    -> BrownfieldSliceCheck.AssertionJudgement
  {
    .unanswered("no judge backend is wired for the brownfield profile")
  }

  /// The slice tier's assertion judge for a clone whose `[judge]` gives `judge`.
  static func assertionJudge(_ judge: BrownfieldJudge?)
    -> @Sendable (AssertionCandidate, String) async -> BrownfieldSliceCheck.AssertionJudgement
  {
    { _, _ in .unanswered("no judge backend is wired for the brownfield profile") }
  }
}

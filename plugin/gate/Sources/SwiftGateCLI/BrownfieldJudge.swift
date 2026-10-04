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

  /// The test-quality question whose `no` says the test would pass with its behavior broken.
  static let failsIfBroken = "fails-if-broken"

  /// The test's file, which holds the helpers it may call, is cut to this many characters.
  static let maxContextCharacters = TestJudgeCheck.maxContextCharacters

  /// The cascade for `config`; `nil` when `[judge]` is absent or names no backend. Jev answers
  /// first, once more after a transport or parse error, then Claude; Claude alone when the
  /// backend is Claude.
  static func live(_ config: JudgeConfig, root: URL) -> BrownfieldJudge? {
    guard case .enabled(let backend, let thresholds, _) = config,
      let judge = JudgeFactory.make(
        config, runner: LiveProcessRunner(),
        cacheDirectory: FileJudgeCache(worktree: root).directory)
    else { return nil }
    switch backend {
    case .jev:
      let claude = JudgeBlockReason.liveJudge(root: root)
      return BrownfieldJudge(thresholds: thresholds, testQuality: .testsJev) {
        subject, questions, base in
        try await CascadingJudge(
          jev: judge, claude: claude, base: base,
          policy: CascadingJudge.Policy(thresholds: thresholds, atReadyTier: true)
        ).classifyingAnswers(subject, questions: questions)
      }
    case .claude:
      return BrownfieldJudge(thresholds: thresholds, testQuality: .tests) { subject, questions, _ in
        try await judge.answer(subject, questions: questions)
      }
    }
  }

  /// What the judge reads for `candidate`: its body as the subject, its file as the context.
  static func subject(_ candidate: AssertionCandidate, source: String) -> JudgeSubject {
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
    let first = max(candidate.line, 1)
    let last = min(candidate.endLine, lines.count)
    let body = first <= last ? lines[(first - 1)...(last - 1)].joined(separator: "\n") : ""
    return JudgeSubject(
      id: "\(candidate.path):\(candidate.line)", file: candidate.path, line: candidate.line,
      source: body,
      context: "The test's file, with any helper it calls:\n"
        + String(source.prefix(maxContextCharacters)))
  }

  /// What the judge makes of a test the assertion table found nothing in: assertion-free when
  /// `no` reaches the block threshold, asserting when `yes` reaches the advisory one, else
  /// unanswered.
  func assertion(_ candidate: AssertionCandidate, source: String) async
    -> BrownfieldSliceCheck.AssertionJudgement
  {
    let answers: [JudgeAnswer]
    do {
      answers = try await ask(Self.subject(candidate, source: source), testQuality, .tests)
    } catch {
      return .unanswered("\(error)")
    }
    guard let answer = answers.first(where: { $0.question == Self.failsIfBroken }) else {
      return .unanswered(
        "the judge gave no \(Self.failsIfBroken) answer; answered \(answers.map(\.question).sorted())"
      )
    }
    let passesBroken = answer.probability(of: "no")
    if passesBroken >= thresholds.block { return .assertsNothing }
    if answer.probability(of: "yes") >= thresholds.advisory { return .asserts }
    return .unanswered(
      "the judge was unsure: \(Self.failsIfBroken) no at \(passesBroken), between the advisory "
        + "\(thresholds.advisory) and block \(thresholds.block) thresholds")
  }

  /// The slice tier's assertion judge for a clone whose `[judge]` gives `judge`.
  static func assertionJudge(_ judge: BrownfieldJudge?)
    -> @Sendable (AssertionCandidate, String) async -> BrownfieldSliceCheck.AssertionJudgement
  {
    guard let judge else { return { _, _ in .unanswered(notConfigured) } }
    return { candidate, source in await judge.assertion(candidate, source: source) }
  }
}

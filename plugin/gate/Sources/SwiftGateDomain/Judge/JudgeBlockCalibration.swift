import CryptoKit
import Foundation

/// Which half of a labelled set a case belongs to (spec §10.5). Thresholds are tuned on `tune`;
/// headline metrics and the block calibration read only `report`, so no reported rate comes from
/// cases a threshold was fitted to.
public enum JudgeCaseSplit: String, Sendable, Equatable, CaseIterable {
  case tune
  case report

  /// A case is in `tune` when the first byte of the SHA-256 of its id is below this, about 1 in 3.
  public static let tuneBelow: UInt8 = 0x55

  public static func of(_ caseID: String) -> JudgeCaseSplit {
    // A SHA-256 digest is always 32 bytes.
    Array(SHA256.hash(data: Data(caseID.utf8)))[0] < tuneBelow ? .tune : .report
  }
}

/// A backend's answers to every case of a labelled set, with the identity that gave them: the
/// committed `recording*.json` files under `gate/Fixtures/judge/`.
public struct JudgeRecording: Sendable, Equatable, Codable {
  public let questionSet: String
  public let identity: JudgeIdentity
  public let answers: [String: [JudgeAnswer]]

  public init(questionSet: String, identity: JudgeIdentity, answers: [String: [JudgeAnswer]]) {
    self.questionSet = questionSet
    self.identity = identity
    self.answers = answers
  }
}

/// Whether a backend that needs one has earned the right to block `ready` on its own for one
/// question (spec §7.1). Computed from the committed recordings and labels on every run, so no
/// summary exists that could drift from them or be edited apart from them.
public enum JudgeBlockCalibration {
  /// Person-labelled report-split cases the question needs.
  public static let minimumCases = 30
  /// Of those, cases on each side: where the flag should fire, and where it shouldn't.
  public static let minimumPerSide = 10
  /// The floor for both the true-positive and the true-negative rate.
  public static let minimumRate = 0.8

  public struct Rates: Sendable, Equatable {
    public let positives: Int
    public let negatives: Int
    public let jevTruePositives: Int
    public let jevTrueNegatives: Int
    public let claudeTruePositives: Int
    public let claudeTrueNegatives: Int

    public init(
      positives: Int, negatives: Int, jevTruePositives: Int, jevTrueNegatives: Int,
      claudeTruePositives: Int, claudeTrueNegatives: Int
    ) {
      self.positives = positives
      self.negatives = negatives
      self.jevTruePositives = jevTruePositives
      self.jevTrueNegatives = jevTrueNegatives
      self.claudeTruePositives = claudeTruePositives
      self.claudeTrueNegatives = claudeTrueNegatives
    }
  }

  public enum Decision: Sendable, Equatable {
    case passes(Rates)
    /// `reason` names the first condition that failed.
    case fails(reason: String)
  }

  public static func evaluate(
    question: String, in questions: JudgeQuestionSet, model: String, blockThreshold: Double,
    set: JudgeCalibrationSet, jev: JudgeRecording?, claude: JudgeRecording?
  ) -> Decision {
    let version = questions.versionedID
    // A rendering asks its base's questions unchanged, so the base's labels and Claude's answers
    // to them are the measure; only Jev's recording must be of the rendering itself.
    let labelled = questions.labelsVersion
    let backend = JudgeBackend.jev.rawValue
    guard let blocking = questions.questions.first(where: { $0.id == question }) else {
      return .fails(reason: "\(version) has no question \(question)")
    }
    guard let jev else {
      return .fails(reason: "no recording from \(backend) to calibrate against")
    }
    guard jev.questionSet == version else {
      return .fails(reason: "the \(backend) recording answers \(jev.questionSet), not \(version)")
    }
    guard jev.identity == JudgeIdentity(backend: backend, model: model) else {
      return .fails(
        reason:
          "the \(backend) recording is from \(jev.identity.backend)/\(jev.identity.model), "
          + "not the pinned \(backend)/\(model)")
    }
    guard set.questionSet == labelled else {
      return .fails(reason: "the labels target \(set.questionSet), not \(labelled)")
    }
    let cases = set.cases.compactMap {
      item -> (item: JudgeCalibrationSet.Case, positive: Bool)? in
      guard item.labeller == .person, JudgeCaseSplit.of(item.id) == .report,
        let expected = item.expected[question]
      else { return nil }
      return (item, flagFires(blocking, expected: expected, declaredTier: item.declaredTier))
    }
    guard cases.count >= minimumCases else {
      return .fails(
        reason:
          "\(cases.count) of \(minimumCases) person labels for \(question) in the report split")
    }
    let positives = cases.filter(\.positive).count
    let negatives = cases.count - positives
    guard positives >= minimumPerSide, negatives >= minimumPerSide else {
      return .fails(
        reason:
          "\(positives) where the flag should fire and \(negatives) where it shouldn't; each side "
          + "needs \(minimumPerSide) person labels in the report split")
    }
    guard let claude else {
      return .fails(reason: "no claude recording to compare against")
    }
    guard claude.questionSet == labelled, claude.identity.backend == JudgeBackend.claude.rawValue
    else {
      return .fails(
        reason:
          "the claude recording is from \(claude.identity.backend)/\(claude.identity.model) on "
          + "\(claude.questionSet), not claude on \(labelled)")
    }
    let jevCounts: (truePositives: Int, trueNegatives: Int)
    let claudeCounts: (truePositives: Int, trueNegatives: Int)
    switch (
      correct(cases, question: blocking, recording: jev, blockThreshold: blockThreshold),
      correct(cases, question: blocking, recording: claude, blockThreshold: blockThreshold)
    ) {
    case (.failure(let missing), _):
      return .fails(reason: "the \(backend) recording has no \(question) answer for \(missing.id)")
    case (_, .failure(let missing)):
      return .fails(reason: "the claude recording has no \(question) answer for \(missing.id)")
    case (.success(let found), .success(let compared)):
      jevCounts = found
      claudeCounts = compared
    }
    let checks = [
      ("true-positive", jevCounts.truePositives, claudeCounts.truePositives, positives),
      ("true-negative", jevCounts.trueNegatives, claudeCounts.trueNegatives, negatives),
    ]
    for (name, jevCount, _, total) in checks
    where Double(jevCount) / Double(total) < minimumRate {
      return .fails(
        reason:
          "\(backend)'s \(name) rate \(rate(jevCount, total)) at block_threshold "
          + "\(format(blockThreshold)) is under \(format(minimumRate))")
    }
    // Both backends answered the same cases, so the counts compare without rounding.
    for (name, jevCount, claudeCount, total) in checks where jevCount < claudeCount {
      return .fails(
        reason:
          "\(backend)'s \(name) rate \(rate(jevCount, total)) is under claude's "
          + "\(rate(claudeCount, total)) at block_threshold \(format(blockThreshold))")
    }
    return .passes(
      Rates(
        positives: positives, negatives: negatives, jevTruePositives: jevCounts.truePositives,
        jevTrueNegatives: jevCounts.trueNegatives, claudeTruePositives: claudeCounts.truePositives,
        claudeTrueNegatives: claudeCounts.trueNegatives))
  }

  struct MissingAnswer: Error {
    let id: String
  }

  /// Cases the recording gets right at `blockThreshold`, by side. A labelled case it never
  /// answered fails the count rather than shrinking it.
  static func correct(
    _ labelled: [(item: JudgeCalibrationSet.Case, positive: Bool)], question: JudgeQuestion,
    recording: JudgeRecording, blockThreshold: Double
  ) -> Result<(truePositives: Int, trueNegatives: Int), MissingAnswer> {
    var truePositives = 0
    var trueNegatives = 0
    for (item, positive) in labelled {
      let subject = JudgeSubject(
        id: item.id, file: item.id, line: 1, source: "", context: "",
        declaredTier: item.declaredTier)
      guard let answer = recording.answers[item.id]?.first(where: { $0.question == question.id }),
        let p = JudgePolicy.flaggedProbability(question, answer: answer, subject: subject)
      else { return .failure(MissingAnswer(id: item.id)) }
      switch (p >= blockThreshold, positive) {
      case (true, true): truePositives += 1
      case (false, false): trueNegatives += 1
      default: break
      }
    }
    return .success((truePositives, trueNegatives))
  }

  /// Whether a correct judge's `expected` answer means the flag fires.
  static func flagFires(_ question: JudgeQuestion, expected: String, declaredTier: String) -> Bool {
    switch question.flag {
    case .option(let option): expected == option
    case .notDeclaredTier: expected != declaredTier
    }
  }

  static func rate(_ count: Int, _ total: Int) -> String {
    "\(format(Double(count) / Double(total))) (\(count)/\(total))"
  }

  static func format(_ value: Double) -> String { String(format: "%.2f", value) }
}

extension JudgeBlockAuthority {
  /// Why `identity` may not block on `question`, or `nil` when it may. A backend that needs a
  /// calibration never blocks on `.standing`, so a caller that forgets to evaluate one can't
  /// grant it by accident.
  func refusal(question: String, identity: JudgeIdentity) -> String? {
    let needsCalibration = JudgeBackend(rawValue: identity.backend)?.needsBlockCalibration == true
    switch self {
    case .standing:
      return needsCalibration ? "no block calibration was evaluated" : nil
    case .perQuestion(let decisions):
      switch decisions[question] {
      case .passes: return nil
      case .fails(let reason): return reason
      case nil: return "no block calibration was evaluated"
      }
    }
  }
}

/// What lets a confident answer to a `mayBlock` question block at `ready`.
public enum JudgeBlockAuthority: Sendable, Equatable {
  /// The backend blocks on its answer alone, as Claude always has.
  case standing
  /// Each question blocks only with a passing decision; a question without one stays advisory.
  case perQuestion([String: JudgeBlockCalibration.Decision])
}

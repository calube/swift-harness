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
    .report
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
    .fails(reason: "")
  }
}

/// What lets a confident answer to a `mayBlock` question block at `ready`.
public enum JudgeBlockAuthority: Sendable, Equatable {
  /// The backend blocks on its answer alone, as Claude always has.
  case standing
  /// Each question blocks only with a passing decision; a question without one stays advisory.
  case perQuestion([String: JudgeBlockCalibration.Decision])
}

import CryptoKit
import Foundation

/// Which half of a labelled set a case belongs to (spec §10.5). Thresholds are tuned on `tune`;
/// headline metrics read only `report`, so no reported rate comes from cases a threshold was
/// fitted to.
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

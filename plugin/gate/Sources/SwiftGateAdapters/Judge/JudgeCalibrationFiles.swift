import Foundation
import SwiftGateDomain

/// The labelled set and per-backend recordings the harness ships under `gate/Fixtures/judge/`,
/// read from a harness root to decide, per question, whether a backend may block (spec §7.1).
public enum JudgeCalibrationFiles {
  public static let directory = "gate/Fixtures/judge"
  public static let labelsFile = "labels.json"

  /// Claude's recording keeps its original name; every other backend's is `recording-<backend>.json`.
  public static func recordingFile(for backend: JudgeBackend) -> String {
    ""
  }

  /// A decision for every question in `questions` that may block. A missing root or file is a
  /// failed decision naming it, never a crash and never a block.
  public static func blockDecisions(
    harnessRoot: URL?, questions: JudgeQuestionSet, model: String, blockThreshold: Double
  ) -> [String: JudgeBlockCalibration.Decision] {
    [:]
  }
}

import Foundation
import SwiftGateDomain

/// Reads a `JudgeDataset` from each place one lives (spec §10.2).
public enum JudgeDatasetLoader {
  public static let testQualityID = "test-quality"
  /// The built-in test-quality set, relative to the harness root.
  public static let testQualityDirectory = "gate/Fixtures/judge"
  public static let labelsFile = "labels.json"
  public static let casesDirectory = "cases"
  public static let sourceFile = "Test.swift.txt"
  public static let contextFile = "Change.diff"
  public static let storedRepliesQuestionSetID = "calibrate-design"

  /// The built-in test-quality set under `gate/Fixtures/judge/`.
  public static func testQuality(harnessRoot: URL) throws(JudgeDatasetError) -> JudgeDataset {
    try directory(
      harnessRoot.appending(path: testQualityDirectory, directoryHint: .isDirectory),
      id: testQualityID)
  }

  /// A directory in the built-in set's layout: `labels.json` naming a built-in question set, and
  /// `cases/<id>/` holding `Test.swift.txt` (the source) and `Change.diff` (the context).
  public static func directory(_ url: URL, id: String) throws(JudgeDatasetError) -> JudgeDataset {
    throw .unreadable(path: url.path, reason: "")
  }

  /// A `calibrate design` run's kept replies, each labelled by its seed's expected options.
  public static func storedReplies(root: URL, runID: String) throws(JudgeDatasetError)
    -> JudgeDataset
  {
    throw .unreadable(path: runID, reason: "")
  }

  /// A dataset JSON file.
  public static func file(_ url: URL) throws(JudgeDatasetError) -> JudgeDataset {
    throw .unreadable(path: url.path, reason: "")
  }
}

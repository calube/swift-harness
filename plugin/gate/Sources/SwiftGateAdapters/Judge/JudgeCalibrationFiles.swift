import Foundation
import SwiftGateDomain

/// The labelled set and per-backend recordings the harness ships under `gate/Fixtures/judge/`,
/// read from a harness root to decide, per question, whether a backend may block (spec §7.1).
public enum JudgeCalibrationFiles {
  public static let directory = "gate/Fixtures/judge"
  public static let labelsFile = "labels.json"

  /// Claude's recording keeps its original name; every other backend's is `recording-<backend>.json`.
  public static func recordingFile(for backend: JudgeBackend) -> String {
    switch backend {
    case .claude: "recording.json"
    case .jev: "recording-jev.json"
    }
  }

  /// A decision for every question in `questions` that may block. A missing root or file is a
  /// failed decision naming it, never a crash and never a block.
  public static func blockDecisions(
    harnessRoot: URL?, questions: JudgeQuestionSet, model: String, blockThreshold: Double
  ) -> [String: JudgeBlockCalibration.Decision] {
    let blocking = questions.questions.filter(\.mayBlock).map(\.id)
    func failing(_ reason: String) -> [String: JudgeBlockCalibration.Decision] {
      Dictionary(uniqueKeysWithValues: blocking.map { ($0, .fails(reason: reason)) })
    }
    guard let harnessRoot else {
      return failing("no harness root to read \(directory) from (SWIFTGATE_HARNESS_ROOT is unset)")
    }
    let root = harnessRoot.appending(path: directory, directoryHint: .isDirectory)
    let set: JudgeCalibrationSet
    do {
      set = try JSONDecoder().decode(
        JudgeCalibrationSet.self, from: Data(contentsOf: root.appending(path: labelsFile)))
    } catch {
      return failing("\(directory)/\(labelsFile) unreadable: \(error)")
    }
    let jev: JudgeRecording?
    let claude: JudgeRecording?
    do {
      jev = try recording(in: root, file: recordingFile(for: .jev))
      claude = try recording(in: root, file: recordingFile(for: .claude))
    } catch {
      return failing(error.description)
    }
    return Dictionary(
      uniqueKeysWithValues: blocking.map {
        (
          $0,
          JudgeBlockCalibration.evaluate(
            question: $0, in: questions, model: model, blockThreshold: blockThreshold, set: set,
            jev: jev, claude: claude)
        )
      })
  }

  struct Unreadable: Error, CustomStringConvertible {
    let description: String
  }

  /// `nil` when the file doesn't exist; a file that exists but won't decode is an error.
  static func recording(in root: URL, file: String) throws(Unreadable) -> JudgeRecording? {
    let url = root.appending(path: file)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    do {
      return try JSONDecoder().decode(JudgeRecording.self, from: Data(contentsOf: url))
    } catch {
      throw Unreadable(description: "\(directory)/\(file) unreadable: \(error)")
    }
  }
}

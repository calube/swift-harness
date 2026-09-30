import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import Testing

@Suite("judge calibration files: labels and per-backend recordings under a harness root")
struct JudgeCalibrationFilesTests {
  static let pin = "jev-1.13.0"
  /// Ids in the report split: their SHA-256 starts at or above 0x55 (computed with Python's hashlib).
  static let reportIDs = [
    0, 1, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 18, 19, 20, 21, 22, 23, 24, 29, 30, 31, 32,
    33, 34, 35, 36, 37,
  ].map { "case-\($0)" }

  /// A harness root with 30 person labels for `fails-if-broken` (10 where it should flag) and
  /// both backends' recordings answering every case correctly.
  static func harnessRoot() throws -> (root: URL, directory: URL) {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "judge-calibration-files-\(UUID().uuidString)", directoryHint: .isDirectory)
    let directory = root.appending(path: JudgeCalibrationFiles.directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let cases = reportIDs.enumerated().map { index, id in (id: id, positive: index < 10) }
    let set = JudgeCalibrationSet(
      questionSet: "test-quality@1",
      cases: cases.map {
        .init(
          id: $0.id, label: $0.positive ? .useless : .good, declaredTier: "T1",
          expected: ["fails-if-broken": $0.positive ? "no" : "yes"], labeller: .person)
      })
    func recording(_ identity: JudgeIdentity) -> JudgeRecording {
      JudgeRecording(
        questionSet: "test-quality@1", identity: identity,
        answers: Dictionary(
          uniqueKeysWithValues: cases.map {
            let p = $0.positive ? 0.99 : 0.01
            return (
              $0.id,
              [
                JudgeAnswer(
                  question: "fails-if-broken", distribution: ["no": p, "yes": 1 - p],
                  rationale: nil)
              ]
            )
          }))
    }
    try JSONEncoder().encode(set).write(
      to: directory.appending(path: JudgeCalibrationFiles.labelsFile))
    try JSONEncoder().encode(
      recording(JudgeIdentity(backend: "claude", model: "claude-sonnet-5-5"))
    ).write(to: directory.appending(path: JudgeCalibrationFiles.recordingFile(for: .claude)))
    try JSONEncoder().encode(recording(JudgeIdentity(backend: "jev", model: pin))).write(
      to: directory.appending(path: JudgeCalibrationFiles.recordingFile(for: .jev)))
    return (root, directory)
  }

  static func decisions(_ root: URL?) -> [String: JudgeBlockCalibration.Decision] {
    JudgeCalibrationFiles.blockDecisions(
      harnessRoot: root, questions: .tests, model: pin, blockThreshold: 0.9)
  }

  static func reasons(_ root: URL?) -> [String: String] {
    decisions(root).compactMapValues {
      guard case .fails(let reason) = $0 else { return nil }
      return reason
    }
  }

  @Test(
    "labels and recordings read from the harness root decide each blocking question — catches the ready check reading another backend's recording or none"
  )
  func readsEachBlockingQuestion() throws {
    #expect(JudgeCalibrationFiles.recordingFile(for: .jev) == "recording-jev.json")
    #expect(JudgeCalibrationFiles.recordingFile(for: .claude) == "recording.json")
    let (root, _) = try Self.harnessRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let found = Self.decisions(root)

    #expect(Set(found.keys) == ["fails-if-broken", "asserts-implementation"])
    guard case .passes = found["fails-if-broken"] else {
      Issue.record("fails-if-broken should pass: \(String(describing: found["fails-if-broken"]))")
      return
    }
    #expect(Self.reasons(root)["asserts-implementation"]?.contains("0 of 30") == true)
  }

  @Test(
    "no harness root, no labels file or an unreadable recording fails every blocking question naming it — catches a read failure that crashes, blocks, or passes silently"
  )
  func unreadableFilesFailNamed() throws {
    let noRoot = Self.reasons(nil)
    #expect(Set(noRoot.keys) == ["fails-if-broken", "asserts-implementation"])
    #expect(noRoot.values.allSatisfy { $0.contains("SWIFTGATE_HARNESS_ROOT") })

    let (root, directory) = try Self.harnessRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("{".utf8).write(
      to: directory.appending(path: JudgeCalibrationFiles.recordingFile(for: .jev)))
    let corrupt = Self.reasons(root)
    #expect(corrupt.count == 2)
    #expect(corrupt.values.allSatisfy { $0.contains("recording-jev.json unreadable") })

    try FileManager.default.removeItem(
      at: directory.appending(path: JudgeCalibrationFiles.recordingFile(for: .jev)))
    #expect(Self.reasons(root)["fails-if-broken"]?.contains("no recording") == true)

    try FileManager.default.removeItem(
      at: directory.appending(path: JudgeCalibrationFiles.labelsFile))
    let noLabels = Self.reasons(root)
    #expect(noLabels.count == 2)
    #expect(noLabels.values.allSatisfy { $0.contains("labels.json unreadable") })
  }
}

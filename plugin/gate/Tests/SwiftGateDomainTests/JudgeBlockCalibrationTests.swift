import Foundation
import Testing

@testable import SwiftGateDomain

@Suite("judge labelled sets: the tune and report split, and who labelled each case")
struct JudgeBlockCalibrationTests {
  /// SHA-256 starts with 0x54: the highest first byte still in the tune split.
  static let tuneID = "case-112"

  // MARK: - Split

  @Test(
    "the split puts a case in tune when its id's SHA-256 starts below 0x55 — catches a report metric read from cases a threshold was tuned on"
  )
  func splitByHash() {
    #expect(JudgeCaseSplit.of(Self.tuneID) == .tune)
    #expect(JudgeCaseSplit.of("case-2") == .tune)
    #expect(JudgeCaseSplit.of("case-52") == .report)
    #expect(JudgeCaseSplit.of("case-0") == .report)
  }

  // MARK: - Labeller

  @Test(
    "a labelled case decodes its labeller, and one without it reads as agent — catches today's tuning-agent labels counting as a person's"
  )
  func labellerDecodes() throws {
    let json = """
      {"schema": 1, "questionSet": "test-quality@1", "cases": [
        {"id": "a", "label": "good", "declaredTier": "T1", "expected": {}, "labeller": "person"},
        {"id": "b", "label": "good", "declaredTier": "T1", "expected": {}, "labeller": "agent"},
        {"id": "c", "label": "good", "declaredTier": "T1", "expected": {}}
      ]}
      """
    let set = try JSONDecoder().decode(JudgeCalibrationSet.self, from: Data(json.utf8))
    #expect(set.cases.map(\.labeller) == [.person, .agent, .agent])
    let roundTripped = try JSONDecoder().decode(
      JudgeCalibrationSet.self, from: JSONEncoder().encode(set))
    #expect(roundTripped.cases.map(\.labeller) == [.person, .agent, .agent])
  }

  @Test(
    "an unknown labeller fails decoding — catches a typo like `persons` silently reading as agent or person"
  )
  func unknownLabellerFails() {
    let json = """
      {"schema": 1, "questionSet": "test-quality@1", "cases": [
        {"id": "a", "label": "good", "declaredTier": "T1", "expected": {}, "labeller": "persons"}
      ]}
      """
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(JudgeCalibrationSet.self, from: Data(json.utf8))
    }
  }
}

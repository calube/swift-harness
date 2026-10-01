import Foundation
import SwiftGateDomain
import Testing

@Suite("judge question keys: the key each question goes out to a backend under")
struct JudgeQuestionKeysTests {
  /// What Claude's API accepts as a top-level schema property key.
  static func claudeAccepts(_ key: String) -> Bool {
    key.wholeMatch(of: /[a-zA-Z0-9_.\-]{1,64}/) != nil
  }

  static func set(_ ids: [String]) -> JudgeQuestionSet {
    JudgeQuestionSet(
      id: "keys", version: 1, subjectDescription: "a reply",
      questions: ids.map {
        JudgeQuestion(
          id: $0, text: "Which?", kind: .choice(["a", "b"]), flag: .option("a"), mayBlock: false,
          problem: "calibration question")
      })
  }

  @Test(
    "an id with a slash or over 64 characters goes out under a key Claude accepts, and a safe id under itself — catches a calibrate design question refused with a 400"
  )
  func unsafeIDsGetSafeKeys() {
    let unsafe = [
      "design-challenger/option-on-probe-passed-api/gating-finding-on-failed-probe",
      "design-drafter/point-with-supported-claim/interval-tag",
      String(repeating: "x", count: 65),
      "",
    ]
    let keys = JudgeQuestionKeys(Self.set(unsafe + ["fails-if-broken"]))

    for id in unsafe {
      #expect(JudgeQuestionKeys.isSafe(keys.key(for: id)), "\(id) → \(keys.key(for: id))")
      #expect(Self.claudeAccepts(keys.key(for: id)), "\(id) → \(keys.key(for: id))")
    }
    #expect(keys.key(for: "fails-if-broken") == "fails-if-broken")
  }

  @Test(
    "every key maps back to exactly its own id — catches an answer credited to another question"
  )
  func keysRoundTrip() {
    let ids = [
      "design-pre-mortem/bounded-prefetch/download-concurrency",
      "design-pre-mortem/unbounded-prefetch/download-concurrency",
      "design-drafter/point-without-supported-claim/interval-tag",
      "design-drafter/point-without-supported-claim/interval-repeated",
      "tier",
    ]
    let keys = JudgeQuestionKeys(Self.set(ids))

    #expect(ids.allSatisfy { JudgeQuestionKeys.isSafe(keys.key(for: $0)) })
    #expect(ids.map { keys.id(for: keys.key(for: $0)) } == ids)
    #expect(Set(ids.map(keys.key(for:))).count == ids.count)
  }

  @Test(
    "2 ids that sanitise alike, or a safe id equal to another's derived key, still get distinct keys — catches 2 questions answered under 1 key"
  )
  func collidingIDsGetDistinctKeys() {
    let alike = ["agent/seed/check", "agent:seed:check", "agent seed check"]
    let alikeKeys = JudgeQuestionKeys(Self.set(alike))
    let derived = alikeKeys.key(for: "agent/seed/check")
    let taken = ["agent/seed/check", derived]
    let takenKeys = JudgeQuestionKeys(Self.set(taken))

    for (ids, keys) in [(alike, alikeKeys), (taken, takenKeys)] {
      #expect(ids.allSatisfy { JudgeQuestionKeys.isSafe(keys.key(for: $0)) })
      #expect(Set(ids.map(keys.key(for:))).count == ids.count)
      #expect(ids.map { keys.id(for: keys.key(for: $0)) } == ids)
    }
  }

  @Test(
    "the same set gets the same keys every time — catches a key that changes between the request and the reply"
  )
  func keysAreStable() {
    let ids = ["design-drafter/point-with-supported-claim/interval-tag", "a/b"]
    let first = JudgeQuestionKeys(Self.set(ids))
    let second = JudgeQuestionKeys(Self.set(ids.reversed()))

    #expect(ids.map(first.key(for:)) == ids.map(second.key(for:)))
    #expect(ids.allSatisfy { first.key(for: $0) != $0 })
  }
}

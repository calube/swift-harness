import Foundation
import Testing

@testable import SwiftGateDomain

@Suite("judge block calibration: split, labeller, the bar a backend must pass to block")
struct JudgeBlockCalibrationTests {
  static let pin = "jev-1.13.0"
  static let question = "fails-if-broken"
  static let threshold = 0.8
  /// Ids whose SHA-256 starts at or above 0x55, computed outside Swift with Python's hashlib.
  static let reportIDs = [
    0, 1, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 18, 19, 20, 21, 22, 23, 24, 29, 30, 31, 32,
    33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 44, 46, 48, 51, 52, 53, 55, 56, 57, 60,
  ].map { "case-\($0)" }
  /// SHA-256 starts with 0x54: the highest first byte still in the tune split.
  static let tuneID = "case-112"

  /// One labelled case: whether the flag should fire, and each backend's flagged probability.
  struct Item {
    var id: String
    var positive: Bool
    var jev: Double
    var claude: Double
    var labeller: JudgeCalibrationSet.Case.Labeller = .person
    var question: String = JudgeBlockCalibrationTests.question
  }

  /// `positives` and `negatives` report-split cases, each backend right on every case except the
  /// first `jevMisses`/`claudeMisses` positives and `jevFalseAlarms`/`claudeFalseAlarms`
  /// negatives. A right answer is 0.99 on the correct side, a wrong one 0.01.
  static func items(
    positives: Int, negatives: Int, jevMisses: Int = 0, jevFalseAlarms: Int = 0,
    claudeMisses: Int = 0, claudeFalseAlarms: Int = 0
  ) -> [Item] {
    var ids = reportIDs[...]
    var items: [Item] = []
    for index in 0..<positives {
      items.append(
        Item(
          id: ids.removeFirst(), positive: true, jev: index < jevMisses ? 0.01 : 0.99,
          claude: index < claudeMisses ? 0.01 : 0.99))
    }
    for index in 0..<negatives {
      items.append(
        Item(
          id: ids.removeFirst(), positive: false, jev: index < jevFalseAlarms ? 0.99 : 0.01,
          claude: index < claudeFalseAlarms ? 0.99 : 0.01))
    }
    return items
  }

  /// Both blocking questions are binary; `fails-if-broken` flags `no`, `asserts-implementation`
  /// flags `yes`.
  static func flagOption(_ question: String) -> (flag: String, other: String) {
    question == "fails-if-broken" ? ("no", "yes") : ("yes", "no")
  }

  static func set(_ items: [Item], questionSet: String = "test-quality@1") -> JudgeCalibrationSet {
    JudgeCalibrationSet(
      questionSet: questionSet,
      cases: items.map { item in
        let (flag, other) = flagOption(item.question)
        return JudgeCalibrationSet.Case(
          id: item.id, label: item.positive ? .useless : .good, declaredTier: "T1",
          expected: [item.question: item.positive ? flag : other], labeller: item.labeller)
      })
  }

  static func recording(
    _ items: [Item], backend: String, model: String, questionSet: String = "test-quality@1",
    probability: (Item) -> Double
  ) -> JudgeRecording {
    JudgeRecording(
      questionSet: questionSet, identity: JudgeIdentity(backend: backend, model: model),
      answers: Dictionary(
        uniqueKeysWithValues: items.map { item in
          let (flag, other) = flagOption(item.question)
          let p = probability(item)
          return (
            item.id,
            [
              JudgeAnswer(
                question: item.question, distribution: [flag: p, other: 1 - p], rationale: nil)
            ]
          )
        }))
  }

  static func jev(_ items: [Item], model: String = pin) -> JudgeRecording {
    recording(items, backend: "jev", model: model) { $0.jev }
  }

  static func claude(_ items: [Item]) -> JudgeRecording {
    recording(items, backend: "claude", model: "claude-sonnet-5-5") { $0.claude }
  }

  static func evaluate(
    _ items: [Item], question: String = question, threshold: Double = threshold,
    jev: JudgeRecording?? = nil, claude: JudgeRecording?? = nil
  ) -> JudgeBlockCalibration.Decision {
    JudgeBlockCalibration.evaluate(
      question: question, in: .tests, model: pin, blockThreshold: threshold, set: set(items),
      jev: jev ?? Self.jev(items), claude: claude ?? Self.claude(items))
  }

  static func reason(_ decision: JudgeBlockCalibration.Decision) -> String? {
    guard case .fails(let reason) = decision else { return nil }
    return reason
  }

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

  // MARK: - Backend

  @Test(
    "only jev needs a block calibration — catches Claude's blocking answers downgraded, or Jev's let through"
  )
  func backendNeeds() {
    #expect(!JudgeBackend.claude.needsBlockCalibration)
    #expect(JudgeBackend.jev.needsBlockCalibration)
  }

  // MARK: - The bar

  @Test(
    "30 person labels, 10 on one side, both rates exactly 0.8 and equal to Claude's passes — catches a bar stricter than the one the user set"
  )
  func passesAtEveryBoundary() {
    let items = Self.items(
      positives: 10, negatives: 20, jevMisses: 2, jevFalseAlarms: 4, claudeMisses: 2,
      claudeFalseAlarms: 4)
    #expect(
      Self.evaluate(items)
        == .passes(
          JudgeBlockCalibration.Rates(
            positives: 10, negatives: 20, jevTruePositives: 8, jevTrueNegatives: 16,
            claudeTruePositives: 8, claudeTrueNegatives: 16)))
  }

  @Test("no jev recording fails naming it — catches a Jev block with no calibration")
  func noRecording() {
    let items = Self.items(positives: 10, negatives: 20)
    let reason = Self.reason(Self.evaluate(items, jev: .some(nil)))
    #expect(reason?.contains("no recording") == true)
  }

  @Test(
    "a recording from another model fails naming both models — catches a stale calibration that still blocks after a pin bump"
  )
  func stalePin() throws {
    let items = Self.items(positives: 10, negatives: 20)
    let reason = try #require(
      Self.reason(Self.evaluate(items, jev: Self.jev(items, model: "jev-1.12.0"))))
    #expect(reason.contains("jev-1.12.0"))
    #expect(reason.contains(Self.pin))
  }

  @Test(
    "a recording of another question set version fails naming it — catches a calibration carried across a question change"
  )
  func otherQuestionSet() throws {
    let items = Self.items(positives: 10, negatives: 20)
    let old = Self.recording(items, backend: "jev", model: Self.pin, questionSet: "test-quality@0")
    {
      $0.jev
    }
    let reason = try #require(Self.reason(Self.evaluate(items, jev: old)))
    #expect(reason.contains("test-quality@0"))
  }

  @Test(
    "Claude's recording in the jev slot fails — catches a copied recording.json unlocking Jev")
  func recordingFromAnotherBackend() throws {
    let items = Self.items(positives: 10, negatives: 20)
    let copied = Self.recording(items, backend: "claude", model: Self.pin) { $0.jev }
    let reason = try #require(Self.reason(Self.evaluate(items, jev: copied)))
    #expect(reason.contains("claude/\(Self.pin)"))
  }

  @Test("29 person labels fails naming 29 of 30 — catches a bar below 30 cases")
  func twentyNineLabels() throws {
    let items = Self.items(positives: 10, negatives: 19)
    let reason = try #require(Self.reason(Self.evaluate(items)))
    #expect(reason.contains("29 of 30"))
  }

  @Test(
    "30 labels with 9 on either side fails — catches a rate resting on too few cases of one kind"
  )
  func nineOnOneSide() throws {
    let fewPositives = try #require(
      Self.reason(Self.evaluate(Self.items(positives: 9, negatives: 21))))
    #expect(fewPositives.contains("9 where the flag should fire"))
    let fewNegatives = try #require(
      Self.reason(Self.evaluate(Self.items(positives: 21, negatives: 9))))
    #expect(fewNegatives.contains("9 where it shouldn't"))
  }

  @Test("30 agent labels fails naming 0 of 30 — catches the tuning agent's labels counting")
  func agentLabels() throws {
    let items = Self.items(positives: 10, negatives: 20).map { item in
      var item = item
      item.labeller = .agent
      return item
    }
    let reason = try #require(Self.reason(Self.evaluate(items)))
    #expect(reason.contains("0 of 30"))
  }

  @Test(
    "30 person labels with 1 in the tune split fails naming 29 of 30 — catches a calibration read from cases someone tuned a threshold on"
  )
  func tuneSplitCaseNeverCounts() throws {
    var items = Self.items(positives: 10, negatives: 20)
    items[items.count - 1].id = Self.tuneID
    let reason = try #require(Self.reason(Self.evaluate(items)))
    #expect(reason.contains("29 of 30"))
  }

  @Test(
    "a true-negative rate of 19/24 (0.7917) fails naming it — catches a floor of 0.79 or lower on negatives"
  )
  func trueNegativeRateBelowFloor() throws {
    let items = Self.items(positives: 10, negatives: 24, jevFalseAlarms: 5, claudeFalseAlarms: 5)
    let reason = try #require(Self.reason(Self.evaluate(items)))
    #expect(reason.contains("true-negative rate 0.79 (19/24)"))
  }

  @Test(
    "a true-positive rate of 19/24 (0.7917) fails naming it — catches a floor of 0.79 or lower on positives"
  )
  func truePositiveRateBelowFloor() throws {
    let items = Self.items(positives: 24, negatives: 10, jevMisses: 5, claudeMisses: 5)
    let reason = try #require(Self.reason(Self.evaluate(items)))
    #expect(reason.contains("true-positive rate 0.79 (19/24)"))
  }

  @Test(
    "rates of 0.8 below Claude's on the same cases fail — catches Jev blocking while it judges worse than Claude"
  )
  func belowClaude() throws {
    let positives = Self.items(
      positives: 10, negatives: 20, jevMisses: 2, jevFalseAlarms: 4, claudeMisses: 1,
      claudeFalseAlarms: 4)
    let tpr = try #require(Self.reason(Self.evaluate(positives)))
    #expect(tpr.contains("true-positive rate 0.80 (8/10) is under claude's 0.90 (9/10)"))
    let negatives = Self.items(
      positives: 10, negatives: 20, jevMisses: 2, jevFalseAlarms: 4, claudeMisses: 2,
      claudeFalseAlarms: 3)
    let tnr = try #require(Self.reason(Self.evaluate(negatives)))
    #expect(tnr.contains("true-negative rate 0.80 (16/20) is under claude's 0.85 (17/20)"))
  }

  @Test("no Claude recording fails naming it — catches the comparison with Claude skipped")
  func noClaudeRecording() throws {
    let items = Self.items(positives: 10, negatives: 20)
    let reason = try #require(Self.reason(Self.evaluate(items, claude: .some(nil))))
    #expect(reason.contains("no claude recording"))
  }

  @Test(
    "an unknown question, labels for another question set, or a claude recording that is not claude's on this set or misses a case fails naming it — catches a comparison against the wrong baseline"
  )
  func mismatchedInputs() throws {
    let items = Self.items(positives: 10, negatives: 20)
    let unknown = try #require(Self.reason(Self.evaluate(items, question: "tier-guess")))
    #expect(unknown.contains("no question tier-guess"))
    let oldLabels = JudgeBlockCalibration.evaluate(
      question: Self.question, in: .tests, model: Self.pin, blockThreshold: Self.threshold,
      set: Self.set(items, questionSet: "test-quality@0"), jev: Self.jev(items),
      claude: Self.claude(items))
    #expect(Self.reason(oldLabels)?.contains("the labels target test-quality@0") == true)
    let notClaude = Self.recording(items, backend: "jev", model: Self.pin) { $0.claude }
    #expect(
      Self.reason(Self.evaluate(items, claude: notClaude))?.contains(
        "the claude recording is from jev/\(Self.pin)") == true)
    let partial = Self.claude(Array(items.dropFirst()))
    #expect(
      Self.reason(Self.evaluate(items, claude: partial))?.contains(
        "the claude recording has no fails-if-broken answer for \(items[0].id)") == true)
  }

  @Test(
    "a labelled case the jev recording never answered fails naming it — catches a rate computed over only the cases Jev answered"
  )
  func unansweredCase() throws {
    let items = Self.items(positives: 10, negatives: 20)
    let partial = Self.jev(Array(items.dropFirst()))
    let reason = try #require(Self.reason(Self.evaluate(items, jev: partial)))
    #expect(reason.contains(items[0].id))
  }

  @Test(
    "a passing calibration for asserts-implementation leaves fails-if-broken failing — catches a calibration read per backend, not per question"
  )
  func perQuestion() throws {
    let items = Self.items(positives: 10, negatives: 20).map { item in
      var item = item
      item.question = "asserts-implementation"
      return item
    }
    guard case .passes = Self.evaluate(items, question: "asserts-implementation") else {
      Issue.record("asserts-implementation should pass")
      return
    }
    let reason = try #require(Self.reason(Self.evaluate(items, question: "fails-if-broken")))
    #expect(reason.contains("0 of 30"))
  }

  @Test(
    "raising block_threshold from 0.8 to 0.95 turns a pass into a fail on the same recording — catches rates computed at a fixed 0.5"
  )
  func ratesAtTheConfiguredThreshold() throws {
    let items = Self.items(positives: 10, negatives: 20).map { item in
      var item = item
      if item.positive {
        item.jev = 0.9
        item.claude = 0.9
      }
      return item
    }
    guard case .passes = Self.evaluate(items, threshold: 0.8) else {
      Issue.record("0.9 on every positive should pass at 0.8")
      return
    }
    let reason = try #require(Self.reason(Self.evaluate(items, threshold: 0.95)))
    #expect(reason.contains("true-positive rate 0.00 (0/10)"))
  }

  // MARK: - A set based on another version

  static func evaluateNative(
    _ items: [Item], labels: String = "test-quality@1", jev: String, claude: String
  ) -> JudgeBlockCalibration.Decision {
    JudgeBlockCalibration.evaluate(
      question: question, in: .testsJev, model: pin, blockThreshold: threshold,
      set: set(items, questionSet: labels),
      jev: recording(items, backend: "jev", model: pin, questionSet: jev) { $0.jev },
      claude: recording(items, backend: "claude", model: "claude-sonnet-5-5", questionSet: claude) {
        $0.claude
      })
  }

  @Test(
    "a Jev recording of @2-jev passes with @1's labels and Claude's @1 recording — catches labels and Claude's answers that stop counting for the rendering based on them"
  )
  func basedOnVersionCounts() {
    let items = Self.items(positives: 10, negatives: 20)
    let decision = Self.evaluateNative(
      items, jev: "test-quality@2-jev", claude: "test-quality@1")
    guard case .passes(let rates) = decision else {
      Issue.record("expected a pass, got \(decision)")
      return
    }
    #expect(rates.positives == 10)
    #expect(rates.negatives == 20)
  }

  @Test(
    "a Jev recording of @1 fails a @2-jev calibration naming both ids, and so does Claude's @2-jev one — catches 1 rendering's recording calibrating another"
  )
  func otherRenderingFails() throws {
    let items = Self.items(positives: 10, negatives: 20)
    let jevOld = try #require(
      Self.reason(
        Self.evaluateNative(items, jev: "test-quality@1", claude: "test-quality@1")))
    #expect(jevOld.contains("test-quality@1") && jevOld.contains("test-quality@2-jev"))
    let claudeNative = try #require(
      Self.reason(
        Self.evaluateNative(items, jev: "test-quality@2-jev", claude: "test-quality@2-jev")))
    #expect(claudeNative.contains("test-quality@2-jev") && claudeNative.contains("test-quality@1"))
    let nativeLabels = try #require(
      Self.reason(
        Self.evaluateNative(
          items, labels: "test-quality@2-jev", jev: "test-quality@2-jev",
          claude: "test-quality@1")))
    #expect(nativeLabels.contains("labels target test-quality@2-jev"))
  }
}

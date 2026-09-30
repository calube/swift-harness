import Foundation
import Testing

@testable import SwiftGateDomain

/// Every expected value here was worked by hand or computed outside Swift with Python; the
/// comment beside each assertion shows the arithmetic.
@Suite("judge benchmark metrics: rates with n, intervals, calibration, stability, agreement, usage")
struct JudgeBenchmarkMetricsTests {
  /// Ids whose SHA-256 starts at or above 0x55 (report) or below it (tune), from Python's hashlib.
  static let reportIDs = [0, 1, 4, 5, 7, 8, 9, 10, 11].map { "case-\($0)" }
  static let tuneIDs = [2, 3, 6, 17, 25, 26, 27, 28].map { "case-\($0)" }

  /// Binary, flags `no`.
  static let failsIfBroken = JudgeQuestionSet.tests.questions[0]
  /// Choice of T1/T2/T3, flags any tier but the declared one.
  static let tier = JudgeQuestionSet.tests.questions[1]
  /// Score vague/partial/specific, flags `vague`.
  static let nameSpecificity = JudgeQuestionSet.tests.questions[2]
  static let claude = JudgeIdentity(backend: "claude", model: "claude-sonnet-5-5")
  static let jev = JudgeIdentity(backend: "jev", model: "jev-1.13.0")

  /// A `fails-if-broken` case: positive means a correct judge answers `no`.
  static func item(_ id: String, positive: Bool) -> JudgeBenchmarkCase {
    JudgeBenchmarkCase(
      id: id, declaredTier: "T1", expected: [failsIfBroken.id: positive ? "no" : "yes"])
  }

  /// A `fails-if-broken` answer whose flagged probability (`no`) is `p`.
  static func flagged(_ p: Double) -> JudgeAnswer {
    JudgeAnswer(question: failsIfBroken.id, distribution: ["yes": 1 - p, "no": p], rationale: nil)
  }

  /// 1 request per case per repeat; `repeats[r][id]` is the flagged probability.
  static func run(_ repeats: [[String: Double]]) -> JudgeBenchmarkRun {
    run(claude, repeats)
  }

  static func run(_ identity: JudgeIdentity, _ repeats: [[String: Double]])
    -> JudgeBenchmarkRun
  {
    JudgeBenchmarkRun(
      identity: identity,
      repeats: repeats.map { answers in
        answers.mapValues { [JudgeReply(answers: [flagged($0)], usage: nil)] }
      })
  }

  func close(_ value: Double?, _ expected: Double, within tolerance: Double = 1e-9) -> Bool {
    guard let value else { return false }
    return abs(value - expected) <= tolerance
  }

  // MARK: Proportions and Wilson

  @Test(
    "Wilson 95% for 10/11 runs 0.62 to 0.98 — catches a normal-approximation interval or a wrong z")
  func wilsonTenOfEleven() throws {
    // p = 10/11, z = 1.96: center (p + z²/22) / (1 + z²/11) = 0.8032, half-width 0.1806.
    let interval = try #require(JudgeWilson.interval(count: 10, n: 11))
    #expect(close(interval.lower, 0.622_641_563_548_404_3, within: 1e-12))
    #expect(close(interval.upper, 0.983_767_827_114_115_1, within: 1e-12))
    #expect(interval.resamples == nil)
  }

  @Test(
    "Wilson for a perfect 5/5 and 3/3 starts at 0.57 and 0.44 — catches an interval collapsing to 1 on a small perfect score"
  )
  func wilsonPerfectSmallSets() throws {
    let five = try #require(JudgeWilson.interval(count: 5, n: 5))
    let three = try #require(JudgeWilson.interval(count: 3, n: 3))
    #expect(close(five.lower, 0.565_517_535_216_825_1, within: 1e-12))
    #expect(five.upper == 1)
    #expect(close(three.lower, 0.438_502_968_244_954_6, within: 1e-12))
    #expect(three.upper == 1)
  }

  @Test(
    "a rate with n 0 is undefined and says so, never 0 or 1 — catches NaN or a silent 0 on an empty denominator"
  )
  func emptyRateIsUndefined() {
    let empty = JudgeProportion(count: 0, n: 0)
    #expect(empty.value == nil)
    #expect(empty.undefined == .noCases)
    #expect(empty.wilson == nil)
    #expect(empty.description == "undefined (0/0)")
    let some = JudgeProportion(count: 10, n: 11)
    #expect(some.description == "0.91 (10/11)")
    #expect(some.undefined == nil)
    #expect(close(some.value, 10.0 / 11.0))
  }

  // MARK: Counts, rates, accuracy

  @Test(
    "counts, precision, true-positive and true-negative rates and accuracy come from each case's decision — catches swapped sides or a wrong denominator"
  )
  func countsAndRates() {
    // Positives: case-0 flagged at 0.9 (TP), case-1 at 0.2 (FN). Negatives: case-4 at 0.7 (FP),
    // case-5 at 0.1 (TN), case-7 at 0.3 (TN). Precision 1/2, TPR 1/2, TNR 2/3, accuracy 3/5.
    let cases = JudgeReportCases([
      Self.item("case-0", positive: true), Self.item("case-1", positive: true),
      Self.item("case-4", positive: false), Self.item("case-5", positive: false),
      Self.item("case-7", positive: false),
    ])
    let result = JudgeBenchmarkMetrics.question(
      Self.failsIfBroken, cases: cases,
      run: Self.run([["case-0": 0.9, "case-1": 0.2, "case-4": 0.7, "case-5": 0.1, "case-7": 0.3]]),
      threshold: 0.5)
    #expect(result.counts.truePositives == 1)
    #expect(result.counts.falseNegatives == 1)
    #expect(result.counts.falsePositives == 1)
    #expect(result.counts.trueNegatives == 2)
    #expect(result.counts.unscored == 0)
    #expect(result.precision == JudgeProportion(count: 1, n: 2))
    #expect(result.truePositiveRate == JudgeProportion(count: 1, n: 2))
    #expect(result.trueNegativeRate == JudgeProportion(count: 2, n: 3))
    #expect(result.accuracy == JudgeProportion(count: 3, n: 5))
    #expect(result.identity == Self.claude)
    #expect(result.question == "fails-if-broken")
  }

  @Test(
    "with no predicted positives precision is undefined, and with no positives recall is — catches a precision of 0 or 1 when the judge never flags"
  )
  func undefinedPrecisionAndRecall() {
    // 2 negatives, both flagged at 0.1: nothing predicted positive and nothing labelled positive.
    let result = JudgeBenchmarkMetrics.question(
      Self.failsIfBroken,
      cases: JudgeReportCases([
        Self.item("case-0", positive: false), Self.item("case-1", positive: false),
      ]),
      run: Self.run([["case-0": 0.1, "case-1": 0.1]]), threshold: 0.5)
    #expect(result.precision.value == nil)
    #expect(result.precision.description == "undefined (0/0)")
    #expect(result.truePositiveRate.value == nil)
    #expect(result.truePositiveRate.undefined == .noCases)
    #expect(result.trueNegativeRate == JudgeProportion(count: 2, n: 2))
  }

  @Test(
    "a case missing an answer in any repeat, or its label, is unscored — catches a decision resting on fewer repeats than the rest"
  )
  func missingAnswerIsUnscored() {
    let result = JudgeBenchmarkMetrics.question(
      Self.failsIfBroken,
      cases: JudgeReportCases([
        Self.item("case-0", positive: true), Self.item("case-1", positive: true),
        JudgeBenchmarkCase(id: "case-4", declaredTier: "T1", expected: [:]),
      ]),
      run: Self.run([
        ["case-0": 0.9, "case-1": 0.9, "case-4": 0.9], ["case-0": 0.9, "case-4": 0.9],
        ["case-0": 0.9, "case-1": 0.9, "case-4": 0.9],
      ]),
      threshold: 0.5)
    #expect(result.counts.unscored == 2)
    #expect(result.counts.truePositives == 1)
    #expect(result.accuracy.n == 1)
  }

  @Test(
    "1 repeat at the decision threshold counts exactly as self-test's metrics do — catches the benchmark and self-test disagreeing on the positive class"
  )
  func agreesWithSelfTestMetrics() {
    let set = JudgeCalibrationSet(
      questionSet: JudgeQuestionSet.tests.versionedID,
      cases: [
        .init(id: "case-0", label: .useless, declaredTier: "T1", expected: ["tier": "T2"]),
        .init(id: "case-1", label: .good, declaredTier: "T1", expected: ["tier": "T1"]),
        .init(id: "case-4", label: .useless, declaredTier: "T2", expected: ["tier": "T3"]),
        .init(id: "case-5", label: .good, declaredTier: "T2", expected: ["tier": "T2"]),
      ])
    let answers: [String: [JudgeAnswer]] = [
      "case-0": [
        JudgeAnswer(question: "tier", distribution: ["T2": 0.8, "T1": 0.2], rationale: nil)
      ],
      "case-1": [
        JudgeAnswer(question: "tier", distribution: ["T1": 0.3, "T3": 0.7], rationale: nil)
      ],
      "case-4": [
        JudgeAnswer(question: "tier", distribution: ["T2": 0.9, "T3": 0.1], rationale: nil)
      ],
      "case-5": [JudgeAnswer(question: "tier", distribution: ["T2": 1], rationale: nil)],
    ]
    let selfTest = JudgeCalibration.metrics(
      set: set,
      questions: JudgeQuestionSet(
        id: "test-quality", version: 1, subjectDescription: "", questions: [Self.tier]),
      answers: answers)
    let benchmark = JudgeBenchmarkMetrics.question(
      Self.tier,
      cases: JudgeReportCases(
        set.cases.map {
          JudgeBenchmarkCase(id: $0.id, declaredTier: $0.declaredTier, expected: $0.expected)
        }),
      run: JudgeBenchmarkRun(
        identity: Self.claude,
        repeats: [answers.mapValues { [JudgeReply(answers: $0, usage: nil)] }]),
      threshold: JudgeCalibration.decisionThreshold)
    // Flagged = 1 − p(declared): 0.8 TP, 0.7 FP, 0.1 FN, 0 TN.
    #expect(selfTest == [benchmark.counts])
    #expect(benchmark.counts.truePositives == 1)
    #expect(benchmark.counts.falsePositives == 1)
    #expect(benchmark.counts.falseNegatives == 1)
    #expect(benchmark.counts.trueNegatives == 1)
  }

  @Test(
    "a tier question can't score a case with no declared tier — catches a missing tier read as a positive"
  )
  func tierWithoutDeclaredTierIsUnscored() {
    let result = JudgeBenchmarkMetrics.question(
      Self.tier,
      cases: JudgeReportCases([
        JudgeBenchmarkCase(id: "case-0", declaredTier: nil, expected: ["tier": "T2"])
      ]),
      run: JudgeBenchmarkRun(
        identity: Self.claude,
        repeats: [
          [
            "case-0": [
              JudgeReply(
                answers: [JudgeAnswer(question: "tier", distribution: ["T2": 1], rationale: nil)],
                usage: nil)
            ]
          ]
        ]),
      threshold: 0.5)
    #expect(result.counts.unscored == 1)
    #expect(result.accuracy.n == 0)
  }

  // MARK: Brier

  @Test(
    "Brier for 2 binary cases is 0.2 — catches squaring only the flagged option or dividing by options"
  )
  func brierTwoBinaryCases() {
    // case-0 labelled `no`, answered no 0.8: (0.2 − 0)² + (0.8 − 1)² = 0.08.
    // case-1 labelled `yes`, answered no 0.4: (0.6 − 1)² + (0.4 − 0)² = 0.32. Mean 0.2.
    let result = JudgeBenchmarkMetrics.question(
      Self.failsIfBroken,
      cases: JudgeReportCases([
        Self.item("case-0", positive: true), Self.item("case-1", positive: false),
      ]),
      run: Self.run([["case-0": 0.8, "case-1": 0.4]]), threshold: 0.5, resamples: 50)
    #expect(close(result.brier.value, 0.2))
    #expect(result.brier.n == 2)
  }

  @Test(
    "Brier over a 3-level score and over repeats uses the mean distribution — catches a Brier from the last repeat only"
  )
  func brierScoreQuestionOverRepeats() {
    // Repeats vague/partial/specific = (0, 0.2, 0.8) and (0.2, 0.4, 0.4) average to
    // (0.1, 0.3, 0.6). Labelled `specific`: 0.1² + 0.3² + 0.4² = 0.26. Most likely: specific.
    let cases = JudgeReportCases([
      JudgeBenchmarkCase(
        id: "case-0", declaredTier: "T1", expected: ["name-specificity": "specific"])
    ])
    func reply(_ vague: Double, _ partial: Double, _ specific: Double) -> [JudgeReply] {
      [
        JudgeReply(
          answers: [
            JudgeAnswer(
              question: "name-specificity",
              distribution: ["vague": vague, "partial": partial, "specific": specific],
              rationale: nil)
          ], usage: nil)
      ]
    }
    let result = JudgeBenchmarkMetrics.question(
      Self.nameSpecificity, cases: cases,
      run: JudgeBenchmarkRun(
        identity: Self.claude,
        repeats: [["case-0": reply(0, 0.2, 0.8)], ["case-0": reply(0.2, 0.4, 0.4)]]),
      threshold: 0.5, resamples: 50)
    #expect(close(result.brier.value, 0.26))
    #expect(result.accuracy == JudgeProportion(count: 1, n: 1))
  }

  @Test(
    "with no scored cases Brier and the calibration error are undefined with n 0 — catches a Brier of 0 on an empty set"
  )
  func emptyBrierIsUndefined() {
    // The 1 labelled case has no answer, so nothing scores.
    let result = JudgeBenchmarkMetrics.question(
      Self.failsIfBroken, cases: JudgeReportCases([Self.item("case-0", positive: true)]),
      run: Self.run([[:]]), threshold: 0.5)
    #expect(result.counts.unscored == 1)
    #expect(result.brier.value == nil)
    #expect(result.brier.undefined == .noCases)
    #expect(result.brier.n == 0)
    #expect(result.calibrationError.undefined == .noCases)
  }

  // MARK: Reliability

  @Test(
    "10 reliability bins give mean predicted, observed rate and count, and an empty bin reports n 0 not a rate — catches a 0 rate for an empty bin"
  )
  func reliabilityBins() throws {
    let curve = JudgeBenchmarkMetrics.reliability([
      (0.05, false), (0.15, true), (0.18, false), (0.95, true), (0.92, true), (1.0, true),
    ])
    let bins = curve.bins
    try #require(bins.count == 10)
    #expect(bins[0].observed == JudgeProportion(count: 0, n: 1))
    #expect(close(bins[0].meanPredicted, 0.05))
    #expect(bins[1].observed == JudgeProportion(count: 1, n: 2))
    #expect(close(bins[1].meanPredicted, 0.165))
    // 1.0 falls in the top bin with 0.95 and 0.92.
    #expect(bins[9].observed == JudgeProportion(count: 3, n: 3))
    #expect(close(bins[9].meanPredicted, (0.95 + 0.92 + 1.0) / 3))
    #expect(close(bins[9].lower, 0.9))
    #expect(close(bins[9].upper, 1.0))
    let empty = bins[5]
    #expect(empty.observed.n == 0)
    #expect(empty.observed.value == nil)
    #expect(empty.meanPredicted == nil)
    // ECE: 1/6·|0 − 0.05| + 2/6·|0.5 − 0.165| + 3/6·|1 − 0.9567| = 0.141667 (Python).
    #expect(close(curve.calibrationError, 0.141_666_666_666_666_66, within: 1e-12))
  }

  @Test("the calibration error of 5 points is 0.17 — catches an unweighted mean over bins")
  func calibrationErrorFivePoints() {
    // 1/5·0.05 + 2/5·0.335 + 2/5·0.065 = 0.17; an unweighted mean over the 3 bins gives 0.15.
    let error = JudgeBenchmarkMetrics.reliability([
      (0.05, false), (0.15, true), (0.18, false), (0.95, true), (0.92, true),
    ]).calibrationError
    #expect(close(error, 0.17, within: 1e-12))
    #expect(JudgeBenchmarkMetrics.reliability([]).calibrationError == nil)
  }

  // MARK: Stability

  @Test(
    "1 case of 3 flipping over 3 repeats is a flip share of 1/3, with the mean standard deviation — catches a flip counted per repeat, not per case"
  )
  func stabilityFlipShare() {
    // case-4 goes 0.4, 0.6, 0.4: its decision flips. Its population sd is 0.0943; the others' are
    // 0, so the mean is 0.031427 (Python). Majority for case-4 is 1 of 3: no flag.
    let result = JudgeBenchmarkMetrics.question(
      Self.failsIfBroken,
      cases: JudgeReportCases([
        Self.item("case-0", positive: true), Self.item("case-1", positive: false),
        Self.item("case-4", positive: true),
      ]),
      run: Self.run([
        ["case-0": 0.9, "case-1": 0.2, "case-4": 0.4],
        ["case-0": 0.9, "case-1": 0.2, "case-4": 0.6],
        ["case-0": 0.9, "case-1": 0.2, "case-4": 0.4],
      ]),
      threshold: 0.5, resamples: 50)
    guard case .measured(let repeats, let flips, let deviation) = result.stability else {
      Issue.record("expected measured stability, got \(result.stability)")
      return
    }
    #expect(repeats == 3)
    #expect(flips == JudgeProportion(count: 1, n: 3))
    #expect(close(deviation.value, 0.031_426_968_052_735_44, within: 1e-12))
    #expect(deviation.n == 3)
    #expect(result.counts.falseNegatives == 1)
  }

  @Test(
    "a most probable option that changes between repeats is a flip even when the decision holds — catches flips read from the decision alone"
  )
  func stabilityCountsOptionFlips() {
    // Flagged `vague` stays under 0.5, but the top option moves from partial to specific.
    func reply(_ partial: Double, _ specific: Double) -> [JudgeReply] {
      [
        JudgeReply(
          answers: [
            JudgeAnswer(
              question: "name-specificity",
              distribution: ["vague": 0.1, "partial": partial, "specific": specific],
              rationale: nil)
          ], usage: nil)
      ]
    }
    let result = JudgeBenchmarkMetrics.question(
      Self.nameSpecificity,
      cases: JudgeReportCases([
        JudgeBenchmarkCase(
          id: "case-0", declaredTier: "T1", expected: ["name-specificity": "specific"])
      ]),
      run: JudgeBenchmarkRun(
        identity: Self.claude,
        repeats: [
          ["case-0": reply(0.6, 0.3)], ["case-0": reply(0.3, 0.6)], ["case-0": reply(0.3, 0.6)],
        ]),
      threshold: 0.5, resamples: 50)
    guard case .measured(_, let flips, _) = result.stability else {
      Issue.record("expected measured stability, got \(result.stability)")
      return
    }
    #expect(flips == JudgeProportion(count: 1, n: 1))
  }

  @Test(
    "fewer than 3 repeats reports too few repeats rather than a flip share — catches stability claimed from 1 run"
  )
  func stabilityNeedsThreeRepeats() {
    let result = JudgeBenchmarkMetrics.question(
      Self.failsIfBroken, cases: JudgeReportCases([Self.item("case-0", positive: true)]),
      run: Self.run([["case-0": 0.9], ["case-0": 0.1]]), threshold: 0.5, resamples: 50)
    #expect(result.stability == .tooFewRepeats(2))
  }

  // MARK: Agreement

  @Test("κ for a textbook 2×2 of 20, 5, 10, 15 is 0.4 — catches observed agreement reported as κ")
  func kappaTextbook() {
    // Both yes 20, first yes second no 5, first no second yes 10, both no 15 (n 50).
    // pₒ = 35/50 = 0.7; pₑ = 0.5·0.6 + 0.5·0.4 = 0.5; κ = (0.7 − 0.5) / (1 − 0.5) = 0.4.
    let first =
      Array(repeating: true, count: 25) + Array(repeating: false, count: 25)
    let second =
      Array(repeating: true, count: 20) + Array(repeating: false, count: 5)
      + Array(repeating: true, count: 10) + Array(repeating: false, count: 15)
    let kappa = JudgeBenchmarkMetrics.kappa(first, second)
    #expect(close(kappa.value, 0.4, within: 1e-12))
    #expect(kappa.n == 50)
  }

  @Test("κ when both raters give 1 constant label is undefined and says why — catches NaN from 0/0")
  func kappaConstantAgreement() {
    let kappa = JudgeBenchmarkMetrics.kappa([true, true, true], [true, true, true])
    #expect(kappa.value == nil)
    #expect(kappa.undefined == .chanceAgreementIsCertain)
    #expect(kappa.n == 3)
    // Constant but opposite: pₒ = 0, pₑ = 0, so κ = 0.
    #expect(JudgeBenchmarkMetrics.kappa([true, true], [false, false]).value == 0)
    #expect(JudgeBenchmarkMetrics.kappa([], []).undefined == .noCases)
  }

  @Test(
    "the comparison's κ uses each backend's majority over repeats, and differences are first minus second — catches κ from 1 repeat or a reversed difference"
  )
  func comparisonKappaAndDifferences() {
    // Majorities: claude flags case-0, case-1; jev flags case-0, case-4. Agreement on case-0
    // (yes) and case-5 (no): pₒ = 1/2, pₑ = 1/2·1/2 + 1/2·1/2 = 1/2, κ = 0.
    // Brier: claude at 0.9/0.9/0.1/0.1 on labels +,+,−,− is 0.02 per case; jev at 0.9/0.1/0.9/0.1
    // gets 0.02, 1.62, 1.62, 0.02, mean 0.82. Difference 0.02 − 0.82 = −0.8.
    let cases = JudgeReportCases([
      Self.item("case-0", positive: true), Self.item("case-1", positive: true),
      Self.item("case-4", positive: false), Self.item("case-5", positive: false),
    ])
    let claudeAnswers = ["case-0": 0.9, "case-1": 0.9, "case-4": 0.1, "case-5": 0.1]
    // jev's case-1 goes 0.1 in 2 of 3 repeats, so its majority is no flag.
    let jevAnswers = ["case-0": 0.9, "case-1": 0.1, "case-4": 0.9, "case-5": 0.1]
    var jevOutlier = jevAnswers
    jevOutlier["case-1"] = 0.9
    let comparison = JudgeBenchmarkMetrics.compare(
      Self.failsIfBroken, cases: cases,
      Self.run(Self.claude, [claudeAnswers, claudeAnswers, claudeAnswers]),
      Self.run(Self.jev, [jevAnswers, jevOutlier, jevAnswers]), threshold: 0.5, resamples: 50)
    #expect(comparison.first == Self.claude)
    #expect(comparison.second == Self.jev)
    #expect(close(comparison.kappa.value, 0, within: 1e-12))
    #expect(comparison.kappa.n == 4)
    // jev's case-1 mean distribution is no 0.3667: (0.6333 − 0)² + (0.3667 − 1)² = 0.8022.
    let missed: Double = 2 * 0.633_333_333_333_333_3 * 0.633_333_333_333_333_3
    let jevBrier: Double = (0.02 + missed + 1.62 + 0.02) / 4
    #expect(close(comparison.brierDifference.value, 0.02 - jevBrier, within: 1e-12))
    #expect(comparison.brierDifference.n == 4)
    // TPR 2/2 against 1/2; TNR 2/2 against 1/2.
    #expect(close(comparison.truePositiveRateDifference.value, 0.5, within: 1e-12))
    #expect(close(comparison.trueNegativeRateDifference.value, 0.5, within: 1e-12))
    #expect(close(comparison.accuracyDifference.value, 0.5, within: 1e-12))
  }

  @Test(
    "a backend compared with itself has every difference 0 with a 0-width interval — catches each backend resampled on its own, unpaired"
  )
  func pairedDifferences() throws {
    let answers = [
      "case-0": 0.9, "case-1": 0.3, "case-4": 0.6, "case-5": 0.2, "case-7": 0.8, "case-8": 0.45,
    ]
    let cases = JudgeReportCases([
      Self.item("case-0", positive: true), Self.item("case-1", positive: true),
      Self.item("case-4", positive: false), Self.item("case-5", positive: false),
      Self.item("case-7", positive: true), Self.item("case-8", positive: false),
    ])
    let comparison = JudgeBenchmarkMetrics.compare(
      Self.failsIfBroken, cases: cases, Self.run(Self.claude, [answers]),
      Self.run(Self.jev, [answers]), threshold: 0.5, resamples: 200)
    let interval = try #require(comparison.brierDifference.interval)
    #expect(interval.lower == 0)
    #expect(interval.upper == 0)
    #expect(interval.resamples == 200)
    let error = try #require(comparison.calibrationErrorDifference.interval)
    #expect(error.lower == 0 && error.upper == 0)
    #expect(comparison.kappa.value == 1)
  }

  // MARK: Bootstrap

  @Test(
    "SplitMix64 from seed 0 gives the reference sequence — catches a generator that drifts between Swift versions"
  )
  func seededGeneratorReference() {
    // The reference SplitMix64's first 2 outputs for seed 0, from a Python port.
    var generator = JudgeSeededGenerator(seed: 0)
    #expect(generator.next() == 0xE220_A839_7B1D_CDAF)
    #expect(generator.next() == 0x6E78_9E6A_A1B9_65F4)
  }

  @Test(
    "the same seed gives the same bootstrap interval twice and another seed a different one — catches an unseeded bootstrap"
  )
  func bootstrapIsSeeded() throws {
    let values = [0.0, 0.1, 0.9, 0.3, 1.0, 0.05, 0.6, 0.2, 0.75, 0.4, 0.15, 0.5]
    func interval(_ seed: UInt64) -> JudgeInterval? {
      JudgeBootstrap.interval(cases: values.count, seed: seed) { draw in
        draw.map { values[$0] }.reduce(0, +) / Double(draw.count)
      }
    }
    let first = try #require(interval(7))
    #expect(interval(7) == first)
    #expect(interval(8) != first)
    #expect(first.resamples == JudgeBootstrap.resamples)
    #expect(JudgeBootstrap.resamples == 2000)
    // The mean of these 12 values is 0.4167; the interval straddles it and stays inside [0, 1].
    #expect(first.lower < 0.4167 && 0.4167 < first.upper)
    #expect(first.lower > 0 && first.upper < 1)
  }

  @Test(
    "a bootstrap over 2 cases scoring 0 and 1 spans 0 to 1 — catches percentiles read from the wrong ends"
  )
  func bootstrapTwoCases() throws {
    // Resample means are 0, 0.5 or 1 with chances 1/4, 1/2, 1/4, so the 2.5th percentile is 0 and
    // the 97.5th is 1.
    let interval = try #require(
      JudgeBootstrap.interval(cases: 2) { draw in draw.map(Double.init).reduce(0, +) / 2 })
    #expect(interval.lower == 0)
    #expect(interval.upper == 1)
  }

  @Test(
    "a resample where the statistic is undefined drops out and the interval counts the rest — catches κ's 0/0 resamples averaged in as 0"
  )
  func bootstrapDropsUndefinedResamples() throws {
    // Undefined whenever every draw is the same index: 3 of the 27 draws of 3 cases, about 1 in 9.
    let interval = try #require(
      JudgeBootstrap.interval(cases: 3) { draw in Set(draw).count == 1 ? nil : 0.5 })
    let resamples = try #require(interval.resamples)
    #expect(resamples < JudgeBootstrap.resamples)
    #expect(resamples > JudgeBootstrap.resamples / 2)
    #expect(JudgeBootstrap.interval(cases: 3) { _ in nil } == nil)
    #expect(JudgeBootstrap.interval(cases: 0) { _ in 1 } == nil)
  }

  @Test(
    "Brier carries a seeded bootstrap interval with its n — catches a metric shipped without its interval"
  )
  func brierCarriesInterval() throws {
    let cases = JudgeReportCases(
      Self.reportIDs.enumerated().map { Self.item($1, positive: $0 % 2 == 0) })
    let answers = Dictionary(
      uniqueKeysWithValues: Self.reportIDs.enumerated().map { ($1, Double($0) / 10) })
    let first = JudgeBenchmarkMetrics.question(
      Self.failsIfBroken, cases: cases, run: Self.run([answers]), threshold: 0.5, seed: 1)
    let again = JudgeBenchmarkMetrics.question(
      Self.failsIfBroken, cases: cases, run: Self.run([answers]), threshold: 0.5, seed: 1)
    let other = JudgeBenchmarkMetrics.question(
      Self.failsIfBroken, cases: cases, run: Self.run([answers]), threshold: 0.5, seed: 2)
    let interval = try #require(first.brier.interval)
    #expect(interval.resamples == 2000)
    #expect(first == again)
    #expect(first.brier.interval != other.brier.interval)
    #expect(first.calibrationError.interval != nil)
  }

  // MARK: Percentiles and usage

  @Test(
    "a percentile of 1 sample is that sample, and 95% of 1…20 is 19 — catches interpolation or an off-by-one rank"
  )
  func percentiles() {
    #expect(JudgePercentile.of([420], percent: 50) == 420)
    #expect(JudgePercentile.of([420], percent: 95) == 420)
    let twenty = Array((1...20).reversed())
    #expect(JudgePercentile.of(twenty, percent: 50) == 10)
    #expect(JudgePercentile.of(twenty, percent: 95) == 19)
    #expect(JudgePercentile.of([], percent: 50) == nil)
    let empty = JudgePercentiles([])
    #expect(empty.n == 0 && empty.p50 == nil && empty.p95 == nil)
    #expect(JudgePercentiles([300, 100, 200]) == JudgePercentiles([100, 200, 300]))
    #expect(JudgePercentiles([300, 100, 200]).p50 == 200)
  }

  @Test(
    "latency per request and per case, tokens and cost per case and per 1,000 judgments carry their n — catches a missing cost read as $0"
  )
  func usageTotals() {
    // case-0 took 2 requests (1 question each): wall 100 + 300, tokens 10 + 20 in, 1 + 2 out,
    // cost 0.01 + 0.02. case-1 took 1 request answering both questions, wall 200, no cost.
    func reply(_ questions: [String], _ usage: JudgeUsage) -> JudgeReply {
      JudgeReply(
        answers: questions.map {
          JudgeAnswer(question: $0, distribution: ["yes": 1], rationale: nil)
        }, usage: usage)
    }
    let run = JudgeBenchmarkRun(
      identity: Self.jev,
      repeats: [
        [
          "case-0": [
            reply(
              ["fails-if-broken"],
              JudgeUsage(
                inputTokens: 10, outputTokens: 1, costUSD: 0.01, wallMilliseconds: 100,
                backendMilliseconds: 80)),
            reply(
              ["asserts-implementation"],
              JudgeUsage(
                inputTokens: 20, outputTokens: 2, costUSD: 0.02, wallMilliseconds: 300,
                backendMilliseconds: 250)),
          ],
          "case-1": [
            reply(
              ["fails-if-broken", "asserts-implementation"],
              JudgeUsage(inputTokens: 40, outputTokens: 6, wallMilliseconds: 200))
          ],
          // A tune-split case never reaches a headline number.
          "case-2": [reply(["fails-if-broken"], JudgeUsage(costUSD: 5, wallMilliseconds: 9000))],
        ]
      ])
    let usage = JudgeBenchmarkMetrics.usage(
      cases: JudgeReportCases([
        Self.item("case-0", positive: true), Self.item("case-1", positive: true),
        Self.item("case-2", positive: true),
      ]), run: run)
    #expect(usage.identity == Self.jev)
    #expect(usage.requestLatency == JudgePercentiles([100, 300, 200]))
    #expect(usage.requestLatency.p95 == 300)
    #expect(usage.caseLatency == JudgePercentiles([400, 200]))
    #expect(usage.backendLatency == JudgePercentiles([80, 250]))
    // Input (10 + 20 + 40) / 2 = 35; output (1 + 2 + 6) / 2 = 4.5.
    #expect(usage.inputTokensPerCase == .defined(35, n: 2))
    #expect(usage.outputTokensPerCase == .defined(4.5, n: 2))
    // Only case-0 reported cost: 0.03 over 1 case, 2 judgments, so $15 per 1,000.
    #expect(close(usage.costPerCase.value, 0.03, within: 1e-12))
    #expect(usage.costPerCase.n == 1)
    #expect(close(usage.costPerThousandJudgments.value, 15, within: 1e-9))
    #expect(usage.costPerThousandJudgments.n == 2)
  }

  @Test("with no usage reported, tokens and cost are undefined with n 0 — catches a silent $0 cost")
  func usageWithoutReports() {
    // The request reports its wall time and nothing else.
    let usage = JudgeBenchmarkMetrics.usage(
      cases: JudgeReportCases([Self.item("case-0", positive: true)]),
      run: JudgeBenchmarkRun(
        identity: Self.jev,
        repeats: [
          [
            "case-0": [
              JudgeReply(answers: [Self.flagged(0.9)], usage: JudgeUsage(wallMilliseconds: 120))
            ]
          ]
        ]))
    #expect(usage.costPerCase == .undefined(.noCases, n: 0))
    #expect(usage.costPerThousandJudgments == .undefined(.noCases, n: 0))
    #expect(usage.inputTokensPerCase.undefined == .noCases)
    #expect(usage.requestLatency == JudgePercentiles([120]))
    #expect(usage.requestLatency.n == 1)
  }

  // MARK: Splits

  @Test(
    "report cases keep only the report split and tune cases only the tune split — catches a threshold tuned on reported cases"
  )
  func splitsFilterByType() {
    let all =
      Self.reportIDs.prefix(3).map { Self.item($0, positive: true) }
      + Self.tuneIDs.prefix(2).map { Self.item($0, positive: true) }
    let report = JudgeReportCases(all)
    let tune = JudgeTuneCases(all)
    #expect(report.cases.map(\.id) == ["case-0", "case-1", "case-4"])
    #expect(report.excluded == 2)
    #expect(tune.cases.map(\.id) == ["case-2", "case-3"])
    #expect(tune.excluded == 3)
  }

  @Test(
    "a threshold sweep scores tune cases only, at each threshold — catches report cases leaking into a sweep"
  )
  func sweepReadsTuneOnly() {
    // Tune: case-2 positive at 0.6, case-3 negative at 0.4. Report case-0 would add a FN at 0.7.
    let all = [
      Self.item("case-2", positive: true), Self.item("case-3", positive: false),
      Self.item("case-0", positive: true),
    ]
    let points = JudgeBenchmarkMetrics.sweep(
      Self.failsIfBroken, cases: JudgeTuneCases(all),
      run: Self.run([["case-2": 0.6, "case-3": 0.4, "case-0": 0.1]]), thresholds: [0.3, 0.5, 0.7])
    #expect(points.map(\.threshold) == [0.3, 0.5, 0.7])
    #expect(
      points.map(\.truePositiveRate) == [
        JudgeProportion(count: 1, n: 1), JudgeProportion(count: 1, n: 1),
        JudgeProportion(count: 0, n: 1),
      ])
    #expect(
      points.map(\.trueNegativeRate) == [
        JudgeProportion(count: 0, n: 1), JudgeProportion(count: 1, n: 1),
        JudgeProportion(count: 1, n: 1),
      ])
    #expect(points.allSatisfy { $0.counts.unscored == 0 })
  }

  @Test(
    "headline metrics ignore tune-split cases — catches a reported rate that includes cases a threshold was fitted to"
  )
  func headlineReadsReportOnly() {
    let result = JudgeBenchmarkMetrics.question(
      Self.failsIfBroken,
      cases: JudgeReportCases([
        Self.item("case-0", positive: true), Self.item("case-2", positive: true),
      ]),
      run: Self.run([["case-0": 0.9, "case-2": 0.1]]), threshold: 0.5, resamples: 50)
    #expect(result.truePositiveRate == JudgeProportion(count: 1, n: 1))
    #expect(result.counts.unscored == 0)
  }
}

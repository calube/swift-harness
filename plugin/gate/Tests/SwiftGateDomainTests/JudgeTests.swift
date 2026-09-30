import Testing

@testable import SwiftGateDomain

@Suite("judge seam: answers, cache key, policy, calibration")
struct JudgeTests {
  static let thresholds = JudgeThresholds(advisory: 0.6, block: 0.9)
  static let identity = JudgeIdentity(backend: "claude", model: "sonnet")
  static let subject = JudgeSubject(
    id: "CounterTests.increments()", file: "Tests/CounterTests.swift", line: 12,
    source: "@Test func increments() {}", context: "+ count += 1", declaredTier: "T1")

  static func answers(
    failsIfBroken no: Double = 0.1, tierT1: Double = 0.9, vague: Double = 0.1,
    implementation yes: Double = 0.1
  ) -> [JudgeAnswer] {
    [
      JudgeAnswer(
        question: "fails-if-broken", distribution: ["yes": 1 - no, "no": no],
        rationale: "asserts the count"),
      JudgeAnswer(
        question: "tier", distribution: ["T1": tierT1, "T2": 1 - tierT1, "T3": 0], rationale: nil),
      JudgeAnswer(
        question: "name-specificity",
        distribution: ["vague": vague, "partial": 0, "specific": 1 - vague], rationale: nil),
      JudgeAnswer(
        question: "asserts-implementation", distribution: ["yes": yes, "no": 1 - yes],
        rationale: nil),
    ]
  }

  static func findings(_ answers: [JudgeAnswer], ready: Bool) throws -> [Finding] {
    try JudgePolicy.findings(
      subject: subject, answers: answers, questions: .tests, thresholds: thresholds,
      identity: identity, atReadyTier: ready)
  }

  @Test(
    "a confident blocking answer is major only at the ready tier — catches the judge alone turning a fast or push run RED"
  )
  func blocksOnlyAtReady() throws {
    let slop = Self.answers(failsIfBroken: 0.95)
    #expect(try Self.findings(slop, ready: true).map(\.severity) == [.major])
    let early = try Self.findings(slop, ready: false)
    #expect(early.map(\.severity) == [.minor])
    #expect(early.first?.message.contains("blocks at the ready tier") == true)
  }

  @Test(
    "between the thresholds is advisory, below advisory is ignored — catches low-confidence judgments blocking or spamming"
  )
  func thresholdBands() throws {
    #expect(
      try Self.findings(Self.answers(failsIfBroken: 0.7), ready: true).map(\.severity) == [.minor])
    #expect(try Self.findings(Self.answers(failsIfBroken: 0.5), ready: true).isEmpty)
  }

  @Test(
    "questions that may not block stay advisory even when certain — catches a tier or naming opinion failing the gate"
  )
  func advisoryQuestionsNeverBlock() throws {
    let found = try Self.findings(Self.answers(tierT1: 0.02, vague: 0.99), ready: true)
    #expect(Set(found.map(\.ruleID)) == ["judge.tier", "judge.name-specificity"])
    #expect(found.allSatisfy { $0.severity == .minor })
  }

  static let jev = JudgeIdentity(backend: "jev", model: "jev-1.13.0")
  static let passing = JudgeBlockCalibration.Decision.passes(
    JudgeBlockCalibration.Rates(
      positives: 10, negatives: 20, jevTruePositives: 10, jevTrueNegatives: 20,
      claudeTruePositives: 10, claudeTrueNegatives: 20))

  static func jevFindings(
    _ answers: [JudgeAnswer], authority: JudgeBlockAuthority, ready: Bool = true
  ) throws -> [Finding] {
    try JudgePolicy.findings(
      subject: subject, answers: answers, questions: .tests, thresholds: thresholds,
      identity: jev, atReadyTier: ready, blockAuthority: authority)
  }

  @Test(
    "with no calibration evaluated, a jev answer at p=0.99 is minor at ready and says why while claude's is major — catches a Jev block by a caller that forgot the calibration, or Claude's blocks downgraded"
  )
  func jevWithoutDecisionIsAdvisory() throws {
    let claude = try JudgePolicy.findings(
      subject: Self.subject, answers: Self.answers(failsIfBroken: 0.99), questions: .tests,
      thresholds: Self.thresholds, identity: Self.identity, atReadyTier: true,
      blockAuthority: .standing)
    #expect(claude.map(\.severity) == [.major])
    let found = try Self.jevFindings(Self.answers(failsIfBroken: 0.99), authority: .standing)
    #expect(found.map(\.severity) == [.minor])
    #expect(
      found.first?.message.contains(
        "advisory: jev has no passing block calibration for fails-if-broken on jev-1.13.0") == true)
  }

  @Test(
    "a failed decision keeps a jev answer minor and carries its reason — catches a Jev block with no recording"
  )
  func jevFailedDecisionIsAdvisory() throws {
    let found = try Self.jevFindings(
      Self.answers(failsIfBroken: 0.99),
      authority: .perQuestion(["fails-if-broken": .fails(reason: "no recording from jev")]))
    #expect(found.map(\.severity) == [.minor])
    #expect(
      found.first?.message.contains(
        "advisory: jev has no passing block calibration for fails-if-broken on jev-1.13.0: "
          + "no recording from jev") == true)
    #expect(found.first?.message.contains("blocks at the ready tier") == false)
  }

  @Test(
    "a passing decision for asserts-implementation leaves fails-if-broken minor — catches a calibration read per backend, not per question"
  )
  func jevDecisionIsPerQuestion() throws {
    let found = try Self.jevFindings(
      Self.answers(failsIfBroken: 0.99),
      authority: .perQuestion(["asserts-implementation": Self.passing]))
    #expect(found.map(\.severity) == [.minor])
  }

  @Test(
    "a passing decision lets a jev answer block at ready, and only at ready, where no decision leaves it minor — catches a calibrated Jev never blocking, or blocking a push run"
  )
  func jevPassingDecisionBlocks() throws {
    let undecided = try Self.jevFindings(
      Self.answers(failsIfBroken: 0.99), authority: .perQuestion([:]))
    #expect(undecided.map(\.severity) == [.minor])
    let authority = JudgeBlockAuthority.perQuestion(["fails-if-broken": Self.passing])
    let ready = try Self.jevFindings(Self.answers(failsIfBroken: 0.99), authority: authority)
    #expect(ready.map(\.severity) == [.major])
    #expect(ready.first?.message.contains("advisory") == false)
    let push = try Self.jevFindings(
      Self.answers(failsIfBroken: 0.99), authority: authority, ready: false)
    #expect(push.map(\.severity) == [.minor])
  }

  @Test("the rationale becomes the failure scenario — catches findings with no reason attached")
  func rationaleCarried() throws {
    let found = try Self.findings(Self.answers(failsIfBroken: 0.95), ready: true)
    #expect(found.first?.failureScenario == "asserts the count")
  }

  @Test(
    "the cache key changes with every input and backend and is stable otherwise — catches stale answers served after a question-set, model or diff change"
  )
  func cacheKey() {
    let base = JudgeCacheKey.make(subject: Self.subject, questions: .tests, identity: Self.identity)
    #expect(
      base == JudgeCacheKey.make(subject: Self.subject, questions: .tests, identity: Self.identity))
    let changedDiff = JudgeSubject(
      id: Self.subject.id, file: Self.subject.file, line: 12, source: Self.subject.source,
      context: "+ count += 2", declaredTier: "T1")
    let variants = [
      JudgeCacheKey.make(subject: changedDiff, questions: .tests, identity: Self.identity),
      JudgeCacheKey.make(subject: Self.subject, questions: .comments, identity: Self.identity),
      JudgeCacheKey.make(
        subject: Self.subject, questions: .tests,
        identity: JudgeIdentity(backend: "claude", model: "opus")),
      JudgeCacheKey.make(
        subject: Self.subject, questions: .tests,
        identity: JudgeIdentity(backend: "jev", model: "sonnet")),
    ]
    #expect(Set(variants + [base]).count == 5)
  }

  @Test(
    "field boundaries can't collide in the cache key — catches two different tests sharing cached answers"
  )
  func cacheKeyUnambiguous() {
    let a = JudgeSubject(id: "a", file: "f", line: 1, source: "ab", context: "c")
    let b = JudgeSubject(id: "a", file: "f", line: 1, source: "a", context: "bc")
    #expect(
      JudgeCacheKey.make(subject: a, questions: .tests, identity: Self.identity)
        != JudgeCacheKey.make(subject: b, questions: .tests, identity: Self.identity))
  }

  @Test(
    "answers missing a question, with unknown options, or not summing to 1 are rejected — catches a malformed backend reply read as a verdict"
  )
  func validation() throws {
    var partial = Self.answers()
    partial.removeLast()
    #expect(throws: JudgeAnswerViolation.missingQuestion("asserts-implementation")) {
      try JudgeAnswers.validate(partial, for: .tests)
    }
    var unknown = Self.answers()
    unknown[0] = JudgeAnswer(
      question: "fails-if-broken", distribution: ["maybe": 1], rationale: nil)
    #expect(
      throws: JudgeAnswerViolation.unknownOptions(question: "fails-if-broken", options: ["maybe"])
    ) {
      try JudgeAnswers.validate(unknown, for: .tests)
    }
    var skewed = Self.answers()
    skewed[0] = JudgeAnswer(
      question: "fails-if-broken", distribution: ["yes": 0.9, "no": 0.9], rationale: nil)
    #expect(throws: JudgeAnswerViolation.self) { try JudgeAnswers.validate(skewed, for: .tests) }
    let rounded =
      [
        JudgeAnswer(
          question: "fails-if-broken", distribution: ["yes": 0.99, "no": 0.02], rationale: nil)
      ] + Self.answers().dropFirst()
    let normalized = try JudgeAnswers.validate(rounded, for: .tests)
    let sum = normalized[0].distribution.values.reduce(0, +)
    #expect(abs(sum - 1) < 1e-9)
    #expect(normalized[0].distribution.keys.sorted() == ["no", "yes"])
  }

  @Test(
    "calibration counts flag-fires as positives per question — catches precision and recall computed against the wrong class"
  )
  func calibrationMetrics() {
    let set = JudgeCalibrationSet(
      questionSet: "test-quality@1",
      cases: [
        .init(id: "good", label: .good, declaredTier: "T1", expected: ["fails-if-broken": "yes"]),
        .init(id: "bad", label: .useless, declaredTier: "T1", expected: ["fails-if-broken": "no"]),
        .init(
          id: "missed", label: .useless, declaredTier: "T1", expected: ["fails-if-broken": "no"]),
        .init(id: "wrong-tier", label: .useless, declaredTier: "T1", expected: ["tier": "T2"]),
      ])
    let metrics = JudgeCalibration.metrics(
      set: set, questions: .tests,
      answers: [
        "good": Self.answers(failsIfBroken: 0.6), "bad": Self.answers(failsIfBroken: 0.95),
        "missed": Self.answers(failsIfBroken: 0.2), "wrong-tier": Self.answers(tierT1: 0.1),
      ])
    let fails = metrics.first { $0.question == "fails-if-broken" }
    #expect(fails?.truePositives == 1)
    #expect(fails?.falsePositives == 1)
    #expect(fails?.falseNegatives == 1)
    #expect(fails?.precision == 0.5)
    #expect(fails?.recall == 0.5)
    let tier = metrics.first { $0.question == "tier" }
    #expect(tier?.truePositives == 1)
  }

  @Test(
    "a question below its baseline, or with unscored cases, is a regression — catches a question-set change that quietly makes the judge worse"
  )
  func regressions() {
    let metrics = [
      JudgeQuestionMetrics(
        question: "fails-if-broken", truePositives: 1, falsePositives: 1, falseNegatives: 0,
        trueNegatives: 5, unscored: 0),
      JudgeQuestionMetrics(
        question: "asserts-implementation", truePositives: 0, falsePositives: 0,
        falseNegatives: 3, trueNegatives: 5, unscored: 0),
      JudgeQuestionMetrics(
        question: "tier", truePositives: 0, falsePositives: 0, falseNegatives: 0,
        trueNegatives: 5, unscored: 2),
    ]
    let baseline = JudgeBaseline(
      questionSet: "test-quality@1",
      minimums: [
        "fails-if-broken": .init(precision: 0.8, recall: 0.8),
        "asserts-implementation": .init(precision: 0.5, recall: 0.5),
      ])
    let found = JudgeCalibration.regressions(metrics, baseline: baseline)
    #expect(found.count == 3)
    #expect(found.contains("fails-if-broken: precision 0.50 < 0.80"))
    #expect(found.contains { $0.hasPrefix("asserts-implementation: precision 0.00") })
    #expect(found.contains("tier: 2 cases unscored"))
  }
}

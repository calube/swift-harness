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

  @Test(
    "a jev answer at p=0.99 is major at ready and minor below it, exactly as claude's — catches a Jev block held back for a calibration"
  )
  func jevBlocksLikeClaude() throws {
    for identity in [JudgeIdentity(backend: "jev", model: "jev-1.13.0"), Self.identity] {
      let ready = try JudgePolicy.findings(
        subject: Self.subject, answers: Self.answers(failsIfBroken: 0.99), questions: .tests,
        thresholds: Self.thresholds, identity: identity, atReadyTier: true)
      #expect(ready.map(\.severity) == [.major], "\(identity.backend)")
      #expect(ready.first?.message.contains("advisory") == false, "\(identity.backend)")
      let push = try JudgePolicy.findings(
        subject: Self.subject, answers: Self.answers(failsIfBroken: 0.99), questions: .tests,
        thresholds: Self.thresholds, identity: identity, atReadyTier: false)
      #expect(push.map(\.severity) == [.minor], "\(identity.backend)")
    }
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

@Suite("self-test scoring of each backend's recording")
struct JudgeRecordingScoreTests {
  static let questions = JudgeQuestionSet.tests
  static let jevFile = "recording-jev.json"
  static let claudeFile = "recording.json"

  static func failsIfBroken(_ flagged: Double) -> [JudgeAnswer] {
    JudgeTests.answers(failsIfBroken: flagged)
  }

  static func recording(
    _ backend: String, _ model: String, served: [String]?,
    answers: [String: [JudgeAnswer]] = [:], usage: [String: JudgeUsage]? = nil
  ) -> JudgeCalibrationRecording {
    JudgeCalibrationRecording(
      questionSet: questions.versionedID, identity: JudgeIdentity(backend: backend, model: model),
      servedModels: served, answers: answers, usage: usage)
  }

  /// Ids of the split asked for, in a stable order.
  static func ids(in split: JudgeCaseSplit, count: Int) -> [String] {
    Array((0..<200).map { "case-\($0)" }.filter { JudgeCaseSplit.of($0) == split }.prefix(count))
  }

  @Test(
    "the true-negative rate over 2 negatives with 1 false positive is 0.5 — catches the true-negative rate computed as recall"
  )
  func trueNegativeRate() throws {
    let set = JudgeCalibrationSet(
      questionSet: Self.questions.versionedID,
      cases: [
        .init(
          id: "flagged", label: .good, declaredTier: "T1", expected: ["fails-if-broken": "yes"]),
        .init(id: "passed", label: .good, declaredTier: "T1", expected: ["fails-if-broken": "yes"]),
      ])
    let score = JudgeCalibration.score(
      set: set, questions: Self.questions,
      answers: ["flagged": Self.failsIfBroken(0.9), "passed": Self.failsIfBroken(0.1)])
    let metric = try #require(score.metrics.first { $0.question == "fails-if-broken" })
    #expect(metric.falsePositives == 1)
    #expect(metric.trueNegatives == 1)
    #expect(metric.trueNegativeRate == 0.5)
  }

  @Test(
    "a question left blank for a case isn't scored and isn't a regression — catches a skipped label failing self-test"
  )
  func blankLabelIsNotARegression() throws {
    let set = JudgeCalibrationSet(
      questionSet: Self.questions.versionedID,
      cases: [.init(id: "tier-only", label: .good, declaredTier: "T1", expected: ["tier": "T1"])])
    let score = JudgeCalibration.score(
      set: set, questions: Self.questions, answers: ["tier-only": JudgeTests.answers()])
    let metric = try #require(score.metrics.first { $0.question == "fails-if-broken" })
    #expect(metric.unscored == 0)
    #expect(score.unrecorded == [])
    let baseline = JudgeBaseline(
      questionSet: Self.questions.versionedID,
      minimums: ["fails-if-broken": .init(precision: 0.8, recall: 0.8)])
    #expect(JudgeCalibration.regressions(score.metrics, baseline: baseline) == [])
  }

  @Test(
    "a labelled case the recording never answered is listed as unrecorded, not scored — catches new labels silently shrinking or failing the scored set"
  )
  func labelledButNotRecorded() throws {
    let set = JudgeCalibrationSet(
      questionSet: Self.questions.versionedID,
      cases: [
        .init(id: "old", label: .good, declaredTier: "T1", expected: ["fails-if-broken": "yes"]),
        .init(id: "new", label: .useless, declaredTier: "T1", expected: ["fails-if-broken": "no"]),
      ])
    let score = JudgeCalibration.score(
      set: set, questions: Self.questions, answers: ["old": Self.failsIfBroken(0.1)])
    #expect(score.unrecorded == ["new"])
    let metric = try #require(score.metrics.first { $0.question == "fails-if-broken" })
    #expect(metric.unscored == 0)
    #expect(metric.trueNegatives == 1)
    #expect(metric.falseNegatives == 0)
  }

  @Test(
    "a Jev recording from jev-1.12.0 is stale and gates, naming both ids — catches a pin bump that keeps an old recording"
  )
  func oldPinIsStale() throws {
    let found = JudgeCalibration.staleness(
      recording: Self.recording("jev", "jev-1.12.0", served: ["jev-1.12.0"]), file: Self.jevFile,
      backend: .jev, baseline: nil, baselineFile: "baseline-jev.json")
    let stale = try #require(found.first { $0.gates })
    #expect(
      stale
        == .offPin(
          file: Self.jevFile, found: JudgeIdentity(backend: "jev", model: "jev-1.12.0"),
          pin: "jev-1.13.0"))
    #expect(stale.description.contains("jev-1.12.0"))
    #expect(stale.description.contains("jev-1.13.0"))
  }

  @Test(
    "a pinned recording answered by another model is stale — catches a recording whose served model left the pin"
  )
  func servedOffPin() {
    let found = JudgeCalibration.staleness(
      recording: Self.recording("jev", "jev-1.13.0", served: ["jev-1.14.0"]), file: Self.jevFile,
      backend: .jev, baseline: nil, baselineFile: "baseline-jev.json")
    #expect(
      found.contains(.servedOffPin(file: Self.jevFile, served: ["jev-1.14.0"], pin: "jev-1.13.0")))
    #expect(found.contains { $0.gates })
  }

  @Test(
    "a Claude recording served by its baseline's model is fresh; one served by another is stale — catches an alias moving under a baseline"
  )
  func baselineServedModel() {
    let recording = Self.recording("claude", "sonnet", served: ["claude-sonnet-5-5"])
    func baseline(_ served: [String]) -> JudgeBaseline {
      JudgeBaseline(questionSet: Self.questions.versionedID, minimums: [:], servedModels: served)
    }
    #expect(
      JudgeCalibration.staleness(
        recording: recording, file: Self.claudeFile, backend: .claude,
        baseline: baseline(["claude-sonnet-5-5"]), baselineFile: "baseline.json") == [])
    let moved = JudgeCalibration.staleness(
      recording: recording, file: Self.claudeFile, backend: .claude,
      baseline: baseline(["claude-sonnet-5-0"]), baselineFile: "baseline.json")
    #expect(
      moved == [
        .baselineServedDiffers(
          file: Self.claudeFile, baselineFile: "baseline.json", baseline: ["claude-sonnet-5-0"],
          recording: ["claude-sonnet-5-5"])
      ])
    #expect(moved.allSatisfy { $0.gates })
  }

  @Test(
    "a recording or baseline that names no served model is a non-gating note — catches an unrecorded served model passing silently or failing the gate"
  )
  func servedUnrecorded() {
    let found = JudgeCalibration.staleness(
      recording: Self.recording("claude", "sonnet", served: nil), file: Self.claudeFile,
      backend: .claude,
      baseline: JudgeBaseline(questionSet: Self.questions.versionedID, minimums: [:]),
      baselineFile: "baseline.json")
    #expect(
      found == [.servedUnrecorded(file: Self.claudeFile), .servedUnrecorded(file: "baseline.json")])
    #expect(!found.contains { $0.gates })
  }

  @Test(
    "a recording holding another backend's answers is stale — catches a Claude recording saved as Jev's"
  )
  func wrongBackend() {
    let found = JudgeCalibration.staleness(
      recording: Self.recording("claude", "sonnet", served: ["claude-sonnet-5-5"]),
      file: Self.jevFile, backend: .jev, baseline: nil, baselineFile: "baseline-jev.json")
    #expect(
      found.contains(
        .wrongBackend(
          file: Self.jevFile, expected: .jev,
          found: JudgeIdentity(backend: "claude", model: "sonnet"))))
    #expect(found.contains { $0.gates })
  }

  @Test(
    "a live run served by another model than the committed recording is stale — catches an alias that moved since the recording"
  )
  func liveServedModel() {
    let committed = Self.recording("claude", "sonnet", served: ["claude-sonnet-5-5"])
    let moved = JudgeCalibration.liveStaleness(
      committed: committed, file: Self.claudeFile,
      live: Self.recording("claude", "sonnet", served: ["claude-sonnet-6-0"]))
    #expect(
      moved
        == .liveServedDiffers(
          file: Self.claudeFile, recording: ["claude-sonnet-5-5"], live: ["claude-sonnet-6-0"]))
    #expect(moved?.gates == true)
    #expect(
      JudgeCalibration.liveStaleness(
        committed: committed, file: Self.claudeFile,
        live: Self.recording("claude", "sonnet", served: ["claude-sonnet-5-5"])) == nil)
    let unnamed = JudgeCalibration.liveStaleness(
      committed: committed, file: Self.claudeFile,
      live: Self.recording("claude", "sonnet", served: nil))
    #expect(unnamed == .servedUnrecorded(file: "the live replies"))
    #expect(unnamed?.gates == false)
  }

  @Test(
    "a recording built from live replies keeps each subject's usage and the sorted served models — catches a recording that drops what answered it"
  )
  func recordingFromReplies() {
    func reply(_ served: String?) -> JudgeReply {
      JudgeReply(
        answers: JudgeTests.answers(),
        usage: JudgeUsage(inputTokens: 10, wallMilliseconds: 50, servedModel: served))
    }
    let recording = JudgeCalibrationRecording(
      questionSet: Self.questions.versionedID,
      identity: JudgeIdentity(backend: "claude", model: "sonnet"),
      replies: ["a": reply("m-2"), "b": reply("m-1"), "c": reply("m-2"), "d": reply(nil)])
    #expect(recording.servedModels == ["m-1", "m-2"])
    #expect(recording.usage?["a"]?.inputTokens == 10)
    #expect(recording.usage?.count == 4)
    #expect(recording.answers["d"] == JudgeTests.answers())
  }

  @Test(
    "the sweep picks the lowest threshold whose tune-split precision meets the baseline — catches the highest or the first threshold being picked"
  )
  func sweepPicksLowest() throws {
    let ids = Self.ids(in: .tune, count: 6)
    let flagged = [0.62, 0.72, 0.9, 0.58, 0.66, 0.1]
    let cases = ids.enumerated().map { index, id in
      JudgeBenchmarkCase(
        id: id, declaredTier: "T1", expected: ["fails-if-broken": index < 3 ? "no" : "yes"])
    }
    let recording = Self.recording(
      "jev", "jev-1.13.0", served: ["jev-1.13.0"],
      answers: Dictionary(
        uniqueKeysWithValues: zip(ids, flagged).map { ($0, Self.failsIfBroken($1)) }))
    let question = try #require(Self.questions.questions.first { $0.id == "fails-if-broken" })
    let lowest = JudgeCalibration.lowestBlockThreshold(
      question, cases: JudgeTuneCases(cases), run: recording.run, minimumPrecision: 0.8)
    #expect(lowest == 0.7)
    #expect(
      JudgeCalibration.lowestBlockThreshold(
        question, cases: JudgeTuneCases(cases), run: recording.run, minimumPrecision: 1.01)
        == nil)
  }

  @Test(
    "latency and cost per subject come from the report split's usage — catches usage read from the tune split or dropped"
  )
  func usageFromReportSplit() {
    let report = Self.ids(in: .report, count: 2)
    let tune = Self.ids(in: .tune, count: 1)
    let set = JudgeCalibrationSet(
      questionSet: Self.questions.versionedID,
      cases: (report + tune).map {
        .init(id: $0, label: .good, declaredTier: "T1", expected: ["fails-if-broken": "yes"])
      })
    let usage = [
      report[0]: JudgeUsage(costUSD: 0.01, wallMilliseconds: 100),
      report[1]: JudgeUsage(costUSD: 0.03, wallMilliseconds: 300),
      tune[0]: JudgeUsage(costUSD: 5, wallMilliseconds: 90_000),
    ]
    let recording = Self.recording(
      "claude", "sonnet", served: ["claude-sonnet-5-5"],
      answers: Dictionary(uniqueKeysWithValues: (report + tune).map { ($0, JudgeTests.answers()) }),
      usage: usage)
    let measured = JudgeCalibration.usage(set: set, recording: recording)
    #expect(measured.requestLatency.n == 2)
    #expect(measured.requestLatency.p95 == 300)
    #expect(measured.costPerCase.value.map { abs($0 - 0.02) < 1e-9 } == true)
    #expect(measured.costPerCase.n == 2)
  }
}

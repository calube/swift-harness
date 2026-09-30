import Testing

@testable import SwiftGateDomain

@Suite("judge cascade: which questions go to claude and who decides each")
struct JudgeCascadeTests {
  static let thresholds = JudgeThresholds(advisory: 0.6, block: 0.9)
  static let jev = JudgeIdentity(backend: "jev", model: "jev-1.13.0")
  static let claude = JudgeIdentity(backend: "claude", model: "claude-sonnet-5-5")
  static let subject = JudgeSubject(
    id: "CounterTests.increments()", file: "Tests/CounterTests.swift", line: 12,
    source: "@Test func increments() {}", context: "+ count += 1", declaredTier: "T1")
  static let bands = JudgeCascade.bands(for: "test-quality@2-jev")
  static let passing = JudgeBlockCalibration.Decision.passes(
    JudgeBlockCalibration.Rates(
      positives: 10, negatives: 20, jevTruePositives: 10, jevTrueNegatives: 20,
      claudeTruePositives: 10, claudeTrueNegatives: 20))
  static let failing = JudgeBlockCalibration.Decision.fails(reason: "no recording from jev")

  static func answers(
    failsIfBroken no: Double = 0.1, vague: Double = 0.1, implementation yes: Double = 0.1,
    rationale: String? = nil
  ) -> [JudgeAnswer] {
    [
      JudgeAnswer(
        question: "fails-if-broken", distribution: ["yes": 1 - no, "no": no], rationale: rationale),
      JudgeAnswer(question: "tier", distribution: ["T1": 0.9, "T2": 0.1, "T3": 0], rationale: nil),
      JudgeAnswer(
        question: "name-specificity",
        distribution: ["vague": vague, "partial": 0, "specific": 1 - vague], rationale: nil),
      JudgeAnswer(
        question: "asserts-implementation", distribution: ["yes": yes, "no": 1 - yes],
        rationale: nil),
    ]
  }

  static func plan(
    _ jev: [JudgeAnswer], decisions: [String: JudgeBlockCalibration.Decision] = [:],
    ready: Bool = true
  ) -> JudgeCascade.Plan {
    JudgeCascade.plan(
      subject: subject, jev: jev, questions: .tests, bands: bands, blockDecisions: decisions,
      thresholds: thresholds, atReadyTier: ready)
  }

  static func findings(
    _ jev: [JudgeAnswer], claude: JudgeCascade.ClaudeOutcome,
    decisions: [String: JudgeBlockCalibration.Decision] = [:]
  ) throws -> [Finding] {
    try JudgeCascade.findings(
      subject: subject, plan: plan(jev, decisions: decisions), jev: jev, claude: claude,
      questions: .tests, jevIdentity: Self.jev, claudeIdentity: Self.claude,
      blockDecisions: decisions, thresholds: thresholds, atReadyTier: true)
  }

  @Test(
    "the 2 blocking questions of the jev-native set have the band 0.2 to 0.8 and no other question or set has one — catches a band on an advisory question or on the set claude asks"
  )
  func bandConstants() {
    let band = JudgeCascade.Band(lower: 0.2, upper: 0.8)
    #expect(Self.bands == ["fails-if-broken": band, "asserts-implementation": band])
    #expect(JudgeCascade.bands(for: "test-quality@1").isEmpty)
  }

  @Test(
    "a jev p of 0.5 on fails-if-broken escalates as uncertain while 0.2 and 0.8 keep — catches a closed band sending edge answers to claude"
  )
  func bandIsOpen() {
    #expect(
      Self.plan(Self.answers(failsIfBroken: 0.5)).step(for: "fails-if-broken")
        == .escalate(.uncertain))
    #expect(Self.plan(Self.answers(failsIfBroken: 0.2)).step(for: "fails-if-broken") == .keep)
    #expect(Self.plan(Self.answers(failsIfBroken: 0.8)).step(for: "fails-if-broken") == .keep)
  }

  @Test(
    "0.5 on name-specificity keeps — catches escalating an advisory question to claude"
  )
  func advisoryNeverEscalates() {
    let plan = Self.plan(Self.answers(failsIfBroken: 0.5, vague: 0.5))
    #expect(plan.step(for: "name-specificity") == .keep)
    #expect(plan.escalated == ["fails-if-broken"])
  }

  @Test(
    "a case with 1 uncertain question escalates exactly that question — catches escalating the whole case"
  )
  func escalatesPerQuestion() {
    let plan = Self.plan(Self.answers(vague: 0.5, implementation: 0.5))
    #expect(plan.escalated == ["asserts-implementation"])
    #expect(plan.escalations == ["asserts-implementation": .uncertain])
    #expect(plan.entries.map(\.question) == JudgeQuestionSet.tests.questions.map(\.id))
  }

  @Test(
    "0.95 with a failing block decision escalates as an uncalibrated block, and with a passing one keeps and is major under jev — catches a confident uncalibrated jev flag turning into a note"
  )
  func uncalibratedBlockEscalates() throws {
    let slop = Self.answers(failsIfBroken: 0.95)
    #expect(
      Self.plan(slop, decisions: ["fails-if-broken": Self.failing]).step(for: "fails-if-broken")
        == .escalate(.uncalibratedBlock))
    #expect(Self.plan(slop).step(for: "fails-if-broken") == .escalate(.uncalibratedBlock))
    let calibrated: [String: JudgeBlockCalibration.Decision] = ["fails-if-broken": Self.passing]
    #expect(Self.plan(slop, decisions: calibrated).escalated.isEmpty)
    let found = try Self.findings(slop, claude: .answered([]), decisions: calibrated)
    #expect(found.map(\.severity) == [.major])
    #expect(found.first?.message.contains("jev/jev-1.13.0") == true)
  }

  @Test(
    "below the ready tier a confident uncalibrated jev answer keeps — catches asking claude for a block that can't happen"
  )
  func uncalibratedBlockOnlyAtReady() {
    let slop = Self.answers(failsIfBroken: 0.95)
    let decisions: [String: JudgeBlockCalibration.Decision] = ["fails-if-broken": Self.failing]
    #expect(Self.plan(slop, decisions: decisions, ready: false).escalated.isEmpty)
    #expect(Self.plan(slop, decisions: decisions, ready: true).escalated == ["fails-if-broken"])
  }

  @Test(
    "an escalated claude answer of 0.95 is major under claude's identity with no block decisions — catches an escalated answer judged under jev's calibration"
  )
  func escalatedAnswerHasClaudeAuthority() throws {
    let found = try Self.findings(
      Self.answers(failsIfBroken: 0.5),
      claude: .answered([
        JudgeAnswer(
          question: "fails-if-broken", distribution: ["yes": 0.05, "no": 0.95],
          rationale: "the assertion never reads the count")
      ]))
    #expect(found.map(\.severity) == [.major])
    #expect(found.first?.ruleID == "judge.fails-if-broken")
    #expect(found.first?.message.contains("claude/claude-sonnet-5-5") == true)
    #expect(found.first?.failureScenario == "the assertion never reads the count")
  }

  @Test(
    "an escalated claude answer of 0.1 gives no finding though jev said 0.7 — catches jev's answer surviving escalation"
  )
  func claudeReplacesJev() throws {
    let jev = Self.answers(failsIfBroken: 0.7)
    let claude = JudgeCascade.ClaudeOutcome.answered([
      JudgeAnswer(
        question: "fails-if-broken", distribution: ["yes": 0.9, "no": 0.1], rationale: nil)
    ])
    #expect(try Self.findings(jev, claude: claude).isEmpty)
    let decided = JudgeCascade.merge(
      plan: Self.plan(jev), jev: jev, claude: claude, jevIdentity: Self.jev,
      claudeIdentity: Self.claude)
    let failsIfBroken = decided.first { $0.answer.question == "fails-if-broken" }
    #expect(failsIfBroken?.identity == Self.claude)
    #expect(failsIfBroken?.escalation == .uncertain)
    #expect(failsIfBroken?.answer.probability(of: "no") == 0.1)
    #expect(decided.filter { $0.identity == Self.jev }.count == 3)
  }

  @Test(
    "a missing claude answer for an uncalibrated block at 0.95 is minor with the calibration note and the escalation note — catches a failed escalation blocking or hiding why"
  )
  func failedEscalationStaysMinor() throws {
    let slop = Self.answers(failsIfBroken: 0.95)
    let decisions: [String: JudgeBlockCalibration.Decision] = ["fails-if-broken": Self.failing]
    for outcome in [
      JudgeCascade.ClaudeOutcome.failed("claude is not on PATH"), .answered([]),
    ] {
      let found = try Self.findings(slop, claude: outcome, decisions: decisions)
      #expect(found.map(\.severity) == [.minor])
      let message = found.first?.message ?? ""
      #expect(message.contains("jev/jev-1.13.0"))
      #expect(
        message.contains(
          "advisory: jev has no passing block calibration for fails-if-broken on jev-1.13.0: "
            + "no recording from jev"))
      #expect(message.contains("escalated to claude as an uncalibrated block"))
    }
    let failed = try Self.findings(
      slop, claude: .failed("claude is not on PATH"), decisions: decisions)
    #expect(failed.first?.message.contains("claude is not on PATH") == true)
  }

  @Test(
    "a failed escalation of an uncertain answer over a low block threshold never blocks — catches an uncertain jev answer blocking after claude fails"
  )
  func failedUncertainEscalationNeverBlocks() throws {
    let low = JudgeThresholds(advisory: 0.5, block: 0.7)
    let jev = Self.answers(failsIfBroken: 0.75)
    let decisions: [String: JudgeBlockCalibration.Decision] = ["fails-if-broken": Self.passing]
    let plan = JudgeCascade.plan(
      subject: Self.subject, jev: jev, questions: .tests, bands: Self.bands,
      blockDecisions: decisions, thresholds: low, atReadyTier: true)
    #expect(plan.step(for: "fails-if-broken") == .escalate(.uncertain))
    let found = try JudgeCascade.findings(
      subject: Self.subject, plan: plan, jev: jev, claude: .failed("timed out"),
      questions: .tests, jevIdentity: Self.jev, claudeIdentity: Self.claude,
      blockDecisions: decisions, thresholds: low, atReadyTier: true)
    #expect(found.map(\.severity) == [.minor])
    #expect(found.first?.message.contains("escalated to claude as uncertain") == true)
  }

  @Test(
    "a record sums both calls' cost and wall time when a question escalated, and is unknown when claude's cost is — catches cost counted on 1 backend"
  )
  func recordSumsUsage() {
    let jev = JudgeUsage(costUSD: 0.001, wallMilliseconds: 300)
    let claude = JudgeUsage(costUSD: 0.02, wallMilliseconds: 4000)
    let escalated = JudgeCascade.Record(
      escalations: ["fails-if-broken": .uncertain], jev: jev, claude: claude)
    #expect(escalated.costUSD == 0.021)
    #expect(escalated.wallMilliseconds == 4300)
    let unreported = JudgeCascade.Record(
      escalations: ["fails-if-broken": .uncertain], jev: jev,
      claude: JudgeUsage(wallMilliseconds: 4000))
    #expect(unreported.costUSD == nil)
    let kept = JudgeCascade.Record(escalations: [:], jev: jev, claude: nil)
    #expect(kept.costUSD == 0.001)
    #expect(kept.wallMilliseconds == 300)
  }

  @Test(
    "a band sweep scores only tune cases — catches a band fitted to cases the benchmark reports"
  )
  func sweepReadsTuneOnly() throws {
    let question = try #require(
      JudgeQuestionSet.tests.questions.first { $0.id == "fails-if-broken" })
    func flagged(_ no: Double) -> [JudgeReply] {
      [
        JudgeReply(
          answers: [
            JudgeAnswer(
              question: "fails-if-broken", distribution: ["yes": 1 - no, "no": no], rationale: nil)
          ], usage: nil)
      ]
    }
    // cascade-g, cascade-i and cascade-k are tune cases; cascade-a is a report case.
    let all = [
      JudgeBenchmarkCase(id: "cascade-g", declaredTier: "T1", expected: ["fails-if-broken": "no"]),
      JudgeBenchmarkCase(id: "cascade-i", declaredTier: "T1", expected: ["fails-if-broken": "no"]),
      JudgeBenchmarkCase(id: "cascade-k", declaredTier: "T1", expected: ["fails-if-broken": "yes"]),
      JudgeBenchmarkCase(id: "cascade-a", declaredTier: "T1", expected: ["fails-if-broken": "yes"]),
    ]
    let run = JudgeBenchmarkRun(
      identity: Self.jev,
      repeats: [
        [
          "cascade-g": flagged(0.5), "cascade-i": flagged(0.95), "cascade-k": flagged(0.1),
          "cascade-a": flagged(0.95),
        ]
      ])
    let points = JudgeCascade.sweep(
      question, cases: JudgeTuneCases(all), run: run, threshold: 0.9,
      bands: [JudgeCascade.Band(lower: 0.2, upper: 0.8), JudgeCascade.Band(lower: 0, upper: 1)])
    #expect(
      points.map(\.escalated) == [
        JudgeProportion(count: 1, n: 3), JudgeProportion(count: 3, n: 3),
      ])
    #expect(
      points.map(\.keptCorrect) == [
        JudgeProportion(count: 2, n: 2), JudgeProportion(count: 0, n: 0),
      ])
  }
}

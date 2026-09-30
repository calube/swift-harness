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
  /// A fixed band, so these tests pin the mechanism; the benchmark's results pin the tuned bands.
  static let bands = [
    "fails-if-broken": JudgeCascade.Band(lower: 0.2, upper: 0.8),
    "asserts-implementation": JudgeCascade.Band(lower: 0.2, upper: 0.8),
  ]

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

  static func plan(_ jev: [JudgeAnswer], ready: Bool = true) -> JudgeCascade.Plan {
    JudgeCascade.plan(
      subject: subject, jev: jev, questions: .tests, bands: bands, thresholds: thresholds,
      atReadyTier: ready)
  }

  static func findings(_ jev: [JudgeAnswer], claude: JudgeCascade.ClaudeOutcome) throws
    -> [Finding]
  {
    try JudgeCascade.findings(
      subject: subject, plan: plan(jev), jev: jev, claude: claude, questions: .tests,
      jevIdentity: Self.jev, claudeIdentity: Self.claude, thresholds: thresholds,
      atReadyTier: true)
  }

  @Test(
    "only the 2 blocking questions of the jev-native set have a band, each holding 0.5 — catches a band on an advisory question or on the set claude asks"
  )
  func bandConstants() {
    let bands = JudgeCascade.bands(for: "test-quality@2-jev")
    #expect(Set(bands.keys) == ["fails-if-broken", "asserts-implementation"])
    #expect(bands.values.allSatisfy { $0.contains(0.5) })
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
    "a jev answer of 0.95 on fails-if-broken keeps at ready and below it, and is major under jev at ready — catches a confident jev block sent to claude or held back"
  )
  func confidentJevBlockKeeps() throws {
    let slop = Self.answers(failsIfBroken: 0.95)
    #expect(Self.plan(slop).escalated.isEmpty)
    #expect(Self.plan(slop, ready: false).escalated.isEmpty)
    let found = try Self.findings(slop, claude: .answered([]))
    #expect(found.map(\.severity) == [.major])
    #expect(found.first?.message.contains("(p=0.95, jev/jev-1.13.0)") == true)
    #expect(found.first?.message.contains("advisory") == false)
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
    "a failed or missing claude answer for an uncertain 0.7 is minor under jev with the escalation note, while a confident 0.95 beside it stays jev's and blocks — catches a failed escalation hiding why, or a confident jev answer sent to claude"
  )
  func failedEscalationStaysMinor() throws {
    let jev = Self.answers(failsIfBroken: 0.7, implementation: 0.95)
    for outcome in [
      JudgeCascade.ClaudeOutcome.failed("claude is not on PATH"), .answered([]),
    ] {
      let found = try Self.findings(jev, claude: outcome)
      #expect(found.map(\.ruleID) == ["judge.fails-if-broken", "judge.asserts-implementation"])
      #expect(found.map(\.severity) == [.minor, .major])
      let message = found.first?.message ?? ""
      #expect(message.contains("(p=0.70, jev/jev-1.13.0); escalated to claude as uncertain"))
      #expect(found.last?.message.contains("escalated") == false)
    }
    let failed = try Self.findings(jev, claude: .failed("claude is not on PATH"))
    #expect(failed.first?.message.hasSuffix("which failed: claude is not on PATH") == true)
  }

  @Test(
    "over a low block threshold, a failed escalation of an uncertain 0.75 never blocks while a kept 0.9 does — catches an uncertain jev answer blocking after claude fails"
  )
  func failedUncertainEscalationNeverBlocks() throws {
    let low = JudgeThresholds(advisory: 0.5, block: 0.7)
    let jev = Self.answers(failsIfBroken: 0.75, implementation: 0.9)
    let plan = JudgeCascade.plan(
      subject: Self.subject, jev: jev, questions: .tests, bands: Self.bands, thresholds: low,
      atReadyTier: true)
    #expect(plan.escalations == ["fails-if-broken": .uncertain])
    let found = try JudgeCascade.findings(
      subject: Self.subject, plan: plan, jev: jev, claude: .failed("timed out"),
      questions: .tests, jevIdentity: Self.jev, claudeIdentity: Self.claude, thresholds: low,
      atReadyTier: true)
    #expect(found.map(\.severity) == [.minor, .major])
    #expect(found.first?.message.contains("escalated to claude as uncertain") == true)
  }

  @Test(
    "findings from claude and jev come back in question set order, each under the identity that decided it — catches a report whose order depends on which backend answered"
  )
  func findingsKeepQuestionOrder() throws {
    let found = try Self.findings(
      Self.answers(failsIfBroken: 0.5, vague: 0.7),
      claude: .answered([
        JudgeAnswer(
          question: "fails-if-broken", distribution: ["yes": 0.05, "no": 0.95], rationale: nil)
      ]))
    #expect(found.map(\.ruleID) == ["judge.fails-if-broken", "judge.name-specificity"])
    #expect(found.map(\.severity) == [.major, .minor])
    #expect(found.last?.message.contains("jev/jev-1.13.0") == true)
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

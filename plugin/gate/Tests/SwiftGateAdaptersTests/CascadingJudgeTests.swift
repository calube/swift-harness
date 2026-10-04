import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

@Suite("the Jev-to-Claude cascade")
struct CascadingJudgeTests {
  /// Answers `flagged[question]` (else 0.1) on each question's flagged option, with `usage`, and
  /// records every set it was asked.
  final class MeteredJudge: Judge {
    let identity: JudgeIdentity
    let flagged: [String: Double]
    let usage: JudgeUsage
    let failure: JudgeError?
    private let sets = Mutex<[JudgeQuestionSet]>([])

    init(
      _ identity: JudgeIdentity, flagged: [String: Double], usage: JudgeUsage,
      failure: JudgeError? = nil
    ) {
      self.identity = identity
      self.flagged = flagged
      self.usage = usage
      self.failure = failure
    }

    var asked: [JudgeQuestionSet] { sets.withLock { $0 } }

    func answer(_ subject: JudgeSubject, questions: JudgeQuestionSet) async throws(JudgeError)
      -> [JudgeAnswer]
    {
      try await measuredAnswer(subject, questions: questions).answers
    }

    func measuredAnswer(_ subject: JudgeSubject, questions: JudgeQuestionSet)
      async throws(JudgeError) -> JudgeReply
    {
      sets.withLock { $0.append(questions) }
      if let failure { throw failure }
      return JudgeReply(
        answers: questions.questions.map { question in
          let p = flagged[question.id] ?? 0.1
          let flag: String =
            switch question.flag {
            case .option(let option): option
            case .notDeclaredTier: question.options.first { $0 != subject.declaredTier } ?? "T2"
            }
          let rest = question.options.filter { $0 != flag }
          var distribution = [flag: p]
          for option in rest { distribution[option] = (1 - p) / Double(rest.count) }
          return JudgeAnswer(
            question: question.id, distribution: distribution,
            rationale: identity.backend == "claude" ? "claude's reason" : nil)
        }, usage: usage)
    }
  }

  static let jevIdentity = JudgeIdentity(backend: "jev", model: "jev-1.13.0")
  static let claudeIdentity = JudgeIdentity(backend: "claude", model: "claude-sonnet-5-5")
  static let subject = JudgeSubject(
    id: "t", file: "Tests/T.swift", line: 1, source: "@Test func t() {}", context: "diff",
    declaredTier: "T1")
  static let jevUsage = JudgeUsage(
    inputTokens: 1000, outputTokens: 20, costUSD: 0.00004, wallMilliseconds: 300,
    servedModel: "jev-1.13.0")
  static let claudeUsage = JudgeUsage(
    inputTokens: 3000, outputTokens: 200, costUSD: 0.02, wallMilliseconds: 4000,
    backendMilliseconds: 3500, servedModel: "claude-sonnet-5-5")

  static func cascade(jev: MeteredJudge, claude: MeteredJudge?) -> CascadingJudge {
    CascadingJudge(
      jev: jev, claude: claude, base: .tests,
      policy: CascadingJudge.Policy(
        thresholds: JudgeThresholds(advisory: 0.6, block: 0.9),
        atReadyTier: true))
  }

  /// A Jev judge that throws `failures` in order, then answers 0.1 everywhere, noting the clock's
  /// time at each call.
  final class ClockedJev: Judge {
    let identity = CascadingJudgeTests.jevIdentity
    let clock: FakeRetryClock
    private let state: Mutex<(failures: [JudgeError], times: [Duration])>

    init(failing failures: [JudgeError], clock: FakeRetryClock) {
      self.clock = clock
      state = Mutex((failures, []))
    }

    var times: [Duration] { state.withLock { $0.times } }

    func answer(_ subject: JudgeSubject, questions: JudgeQuestionSet) async throws(JudgeError)
      -> [JudgeAnswer]
    {
      try await measuredAnswer(subject, questions: questions).answers
    }

    func measuredAnswer(_ subject: JudgeSubject, questions: JudgeQuestionSet)
      async throws(JudgeError) -> JudgeReply
    {
      let failure: JudgeError? = state.withLock {
        $0.times.append(clock.now())
        return $0.failures.isEmpty ? nil : $0.failures.removeFirst()
      }
      if let failure { throw failure }
      return try await MeteredJudge(identity, flagged: [:], usage: CascadingJudgeTests.jevUsage)
        .measuredAnswer(subject, questions: questions)
    }
  }

  @Test(
    "at ready, Jev is asked again only after a wait of 0.5 to 1 s following a transport error, and never waits otherwise — catches a retry fired the instant a connection drops"
  )
  func readyRetryWaitsFirst() async throws {
    let retryClock = FakeRetryClock()
    let flaky = ClockedJev(
      failing: [.transport("Jev is unreachable: connection refused")], clock: retryClock)
    let policy = CascadingJudge.Policy(
      thresholds: JudgeThresholds(advisory: 0.6, block: 0.9), atReadyTier: true)

    let reply = try await CascadingJudge(
      jev: flaky, claude: nil, base: .tests, policy: policy, clock: retryClock
    ).readyCascade(Self.subject, questions: .testsJev)

    guard case .cascaded = reply else {
      Issue.record("expected Jev's second answer to stand, got \(reply)")
      return
    }
    #expect(retryClock.sleeps == [CascadingJudge.retryDelay])
    #expect(CascadingJudge.retryDelay >= .milliseconds(500))
    #expect(CascadingJudge.retryDelay <= .seconds(1))
    #expect(flaky.times == [.zero, CascadingJudge.retryDelay])

    for failures in [[], [JudgeError.backend("Jev refused the key (401)")]] {
      let quietClock = FakeRetryClock()
      let jev = ClockedJev(failing: failures, clock: quietClock)
      _ = try await CascadingJudge(
        jev: jev, claude: nil, base: .tests, policy: policy, clock: quietClock
      ).readyCascade(Self.subject, questions: .testsJev)
      #expect(quietClock.sleeps.isEmpty)
      #expect(jev.times == [.zero])
    }
  }

  @Test(
    "Jev at p_no 0.5 on both blocking questions sends Claude 1 request with only those 2 in their @1 text, and the merged answers are Claude's for them and Jev's for the rest — catches the Jev set sent to Claude, or 1 Claude call per question"
  )
  func escalatedQuestionsGoToClaudeInOneRequest() async throws {
    let jev = MeteredJudge(
      Self.jevIdentity, flagged: ["fails-if-broken": 0.5, "asserts-implementation": 0.5],
      usage: Self.jevUsage)
    let claude = MeteredJudge(
      Self.claudeIdentity, flagged: ["fails-if-broken": 0.95, "asserts-implementation": 0.05],
      usage: Self.claudeUsage)

    let reply = try await Self.cascade(jev: jev, claude: claude).cascade(
      Self.subject, questions: .testsJev)

    #expect(jev.asked.map(\.versionedID) == ["test-quality@2-jev"])
    let asked = try #require(claude.asked.count == 1 ? claude.asked.first : nil)
    #expect(asked.rendering == nil)
    #expect(asked.questions == JudgeQuestionSet.tests.questions.filter(\.mayBlock))
    #expect(reply.plan.escalated == ["fails-if-broken", "asserts-implementation"])
    #expect(reply.claudeReply?.usage == Self.claudeUsage)
    let merged = try await Self.cascade(jev: jev, claude: claude).answer(
      Self.subject, questions: .testsJev)
    let byQuestion = Dictionary(uniqueKeysWithValues: merged.map { ($0.question, $0) })
    #expect(byQuestion["fails-if-broken"]?.probability(of: "no") == 0.95)
    #expect(byQuestion["fails-if-broken"]?.rationale == "claude's reason")
    #expect(byQuestion["name-specificity"]?.rationale == nil)
    #expect(merged.map(\.question) == JudgeQuestionSet.tests.questions.map(\.id))
  }

  @Test(
    "Jev at 0.1 everywhere asks Claude nothing and its usage is Jev's alone — catches escalating every question"
  )
  func confidentJevAsksClaudeNothing() async throws {
    let jev = MeteredJudge(Self.jevIdentity, flagged: [:], usage: Self.jevUsage)
    let claude = MeteredJudge(Self.claudeIdentity, flagged: [:], usage: Self.claudeUsage)

    let reply = try await Self.cascade(jev: jev, claude: claude).measuredAnswer(
      Self.subject, questions: .testsJev)

    #expect(claude.asked.isEmpty)
    #expect(jev.asked.count == 1)
    #expect(reply.usage == Self.jevUsage)
  }

  @Test(
    "an escalation's usage sums Jev's and Claude's tokens, cost and wall time — catches cost counted on 1 backend"
  )
  func escalatedUsageSumsBothCalls() async throws {
    let jev = MeteredJudge(
      Self.jevIdentity, flagged: ["fails-if-broken": 0.5], usage: Self.jevUsage)
    let claude = MeteredJudge(Self.claudeIdentity, flagged: [:], usage: Self.claudeUsage)

    let usage = try #require(
      try await Self.cascade(jev: jev, claude: claude).measuredAnswer(
        Self.subject, questions: .testsJev
      ).usage)

    #expect(usage.inputTokens == 4000)
    #expect(usage.outputTokens == 220)
    #expect(abs((usage.costUSD ?? 0) - 0.02004) < 1e-12)
    #expect(usage.wallMilliseconds == 4300)
    #expect(usage.servedModel == "jev-1.13.0")
  }

  @Test(
    "a failing Claude, or none at all, leaves Jev's answers and names why the escalation failed — catches a Claude error failing the subject"
  )
  func failingClaudeKeepsJevAnswers() async throws {
    let jev = MeteredJudge(
      Self.jevIdentity, flagged: ["fails-if-broken": 0.5], usage: Self.jevUsage)
    let claude = MeteredJudge(
      Self.claudeIdentity, flagged: [:], usage: Self.claudeUsage, failure: .backend("overloaded"))

    let failed = try await Self.cascade(jev: jev, claude: claude).cascade(
      Self.subject, questions: .testsJev)
    let missing = try await Self.cascade(jev: jev, claude: nil).cascade(
      Self.subject, questions: .testsJev)

    #expect(failed.claude == .failed("claude reported an error: overloaded"))
    #expect(failed.claudeReply == nil)
    #expect(missing.claude == .failed("no Claude judge is available"))
    #expect(failed.jev.answers == missing.jev.answers)
    #expect(
      failed.jev.answers.first { $0.question == "fails-if-broken" }?.probability(of: "no") == 0.5)
  }
}

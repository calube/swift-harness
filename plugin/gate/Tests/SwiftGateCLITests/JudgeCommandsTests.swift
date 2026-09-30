import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateRules
import SwiftGateTestSupport
import Synchronization
import Testing

@testable import SwiftGateCLI

@Suite("judge wiring: tests, commit comments, calibration")
struct JudgeCommandsTests {
  static let testFile = "XUnitProbe/Tests/ProbeTests/PassTests.swift"
  static let sourceFile = "XUnitProbe/Sources/Probe/Probe.swift"
  static let enabled = """
    \(ProbeRepository.config)

    [judge]
    backend = "claude"
    advisory_threshold = 0.6
    block_threshold = 0.9
    """

  struct Setup {
    let repository: ProbeRepository
    let git: FakeGit

    init(config: String = JudgeCommandsTests.enabled) throws {
      repository = try ProbeRepository(config: config)
      try repository.write(
        JudgeCommandsTests.testFile,
        try String(
          contentsOf: Fixture.gateDirectory.appending(
            path: "Fixtures/swifttest/XUnitProbe/Tests/ProbeTests/PassTests.swift"),
          encoding: .utf8))
      git = FakeGit(
        changed: [JudgeCommandsTests.testFile, JudgeCommandsTests.sourceFile], mergeBase: "base",
        addedSince: [AddedLines(path: JudgeCommandsTests.testFile, ranges: [1...15])])
    }

    var environment: ChangedTestChecks.Environment {
      ChangedTestChecks.Environment(
        root: repository.root, git: git, swiftPM: FakeSwiftPM(serving: []),
        scratch: FakeScratchWorktrees(root: repository.root),
        scratchSwiftPM: { _ in FakeSwiftPM(serving: []) })
    }

    func config() throws -> Config {
      guard case .success(let config?) = StaticCheckInputs.loadConfig(root: repository.root) else {
        throw ConfigMissing()
      }
      return config
    }

    struct ConfigMissing: Error {}
  }

  static func run(_ setup: Setup, judge: FakeJudge?, ready: Bool) async throws -> [Finding] {
    await TestJudgeCheck.run(
      setup.environment, graph: try ModuleGraph(packages: [try ProbeRepository.manifest()]),
      config: try setup.config(), base: "origin/main", atReadyTier: ready,
      dependencies: TestJudgeCheck.Dependencies(
        makeJudge: { _ in judge },
        diff: FakeDiff(
          text:
            "diff --git a/XUnitProbe/Sources/Probe/Probe.swift b/XUnitProbe/Sources/Probe/Probe.swift\n+func doubled() {}\n"
            + "diff --git a/XUnitProbe/Tests/ProbeTests/PassTests.swift b/XUnitProbe/Tests/ProbeTests/PassTests.swift\n+@Test\n"
        )))
  }

  @Test(
    "changed tests are judged with their source and the production diff, and a confident slop answer gates only at ready — catches test source judged without the change it covers"
  )
  func judgesChangedTests() async throws {
    let setup = try Setup()
    defer { setup.repository.remove() }
    let judge = FakeJudge.answering(flagged: 0.95)

    let ready = try await Self.run(setup, judge: judge, ready: true)
    let push = try await Self.run(setup, judge: judge, ready: false)

    let subject = try #require(judge.subjects.first)
    #expect(subject.file == Self.testFile)
    #expect(subject.source.contains("func"))
    #expect(subject.context.contains("Probe.swift"))
    #expect(!subject.context.contains("PassTests.swift"))
    #expect(ready.contains { $0.ruleID == "judge.fails-if-broken" && $0.severity == .major })
    #expect(push.allSatisfy { !$0.severity.failsGate })
    #expect(!push.isEmpty)
  }

  @Test(
    "a disabled judge asks nothing — catches test source sent to a backend the repository never enabled"
  )
  func disabledAsksNothing() async throws {
    let setup = try Setup(config: ProbeRepository.config)
    defer { setup.repository.remove() }
    let judge = FakeJudge.answering(flagged: 0.95)
    let findings = try await Self.run(setup, judge: judge, ready: true)
    #expect(findings.isEmpty)
    #expect(judge.subjects.isEmpty)
  }

  @Test(
    "a failing backend is a non-gating note — catches an API outage failing the ready tier")
  func backendFailureIsNote() async throws {
    let setup = try Setup()
    defer { setup.repository.remove() }
    let judge = FakeJudge { _, _ throws(JudgeError) in throw .backend("overloaded") }
    let findings = try await Self.run(setup, judge: judge, ready: true)
    #expect(findings.map(\.ruleID) == [TestJudgeCheck.notRunRuleID])
    #expect(findings.allSatisfy { !$0.severity.failsGate })
  }

  @Test(
    "staged added comments reach the comment judge and a CUT answer comes back as advice — catches the commit hook ignoring an enabled judge"
  )
  func commitComments() async throws {
    let setup = try Setup()
    defer { setup.repository.remove() }
    let staged = """
      // Increment the counter by one.
      count += 1
      // MARK: - Helpers
      """
    let git = FakeGit(
      staged: ["Sources/A.swift": .init(content: staged, addedLines: [1...3])])
    let judge = FakeJudge.answering(flagged: 0.8)
    let commentJudge = ConfiguredCommitCommentJudge(
      makeJudge: { _, _ in judge }, git: { _ in git })

    let advice = try #require(await commentJudge.review(root: setup.repository.root))

    #expect(judge.subjects.map(\.id) == ["Sources/A.swift:1"])
    #expect(judge.subjects.first?.context.contains("count += 1") == true)
    #expect(advice.contains("CUT"))
    #expect(advice.contains("Sources/A.swift:1"))
  }

  @Test(
    "the comment judge is silent when the judge is disabled — catches comments sent off-machine without opt-in"
  )
  func commitCommentsDisabled() async throws {
    let setup = try Setup(config: ProbeRepository.config)
    defer { setup.repository.remove() }
    let judge = FakeJudge.answering(flagged: 0.8)
    let git = FakeGit(staged: ["A.swift": .init(content: "// hi\nlet a = 1\n", addedLines: [1...2])]
    )
    let commentJudge = ConfiguredCommitCommentJudge(
      makeJudge: { _, _ in judge }, git: { _ in git })
    #expect(await commentJudge.review(root: setup.repository.root) == nil)
    #expect(judge.subjects.isEmpty)
  }

  @Test(
    "calibration against the labeled set: a judge that matches the labels is GREEN, one that flags everything regresses — catches a question-set or backend change that makes the judge worse"
  )
  func calibration() async throws {
    let labels = try JSONDecoder().decode(
      JudgeCalibrationSet.self,
      from: Data(
        contentsOf: Fixture.checkoutRoot.appending(path: "gate/Fixtures/judge/labels.json")))
    #expect(labels.cases.filter { $0.label == .good }.count >= 10)
    #expect(labels.cases.filter { $0.label == .useless }.count >= 10)
    let byID = Dictionary(uniqueKeysWithValues: labels.cases.map { ($0.id, $0) })
    let oracle = FakeJudge { subject, questions throws(JudgeError) in
      questions.questions.map { question in
        let expected = byID[subject.id]?.expected[question.id] ?? question.options[0]
        return JudgeAnswer(
          question: question.id,
          distribution: Dictionary(
            uniqueKeysWithValues: question.options.map { ($0, $0 == expected ? 1.0 : 0.0) }),
          rationale: nil)
      }
    }

    let good = await JudgeSelfTest.run(
      harnessRoot: Fixture.checkoutRoot, judge: oracle, record: false)
    let bad = await JudgeSelfTest.run(
      harnessRoot: Fixture.checkoutRoot, judge: FakeJudge.answering(flagged: 0.9), record: false)

    guard case .checked(let goodResult) = good, case .checked(let badResult) = bad else {
      Issue.record("expected both calibrations to run, got \(good) and \(bad)")
      return
    }
    #expect(!goodResult.findings.contains { $0.severity.failsGate })
    #expect(goodResult.findings.contains { $0.ruleID == JudgeSelfTest.metricsRuleID })
    #expect(badResult.findings.contains { $0.ruleID == JudgeSelfTest.ruleID })
  }

  @Test(
    "the stored recording meets the baseline offline — catches a recorded backend that no longer calibrates"
  )
  func recordedCalibration() async throws {
    let outcome = await JudgeSelfTest.run(
      harnessRoot: Fixture.checkoutRoot, judge: nil, record: false)
    guard case .checked(let result) = outcome else {
      Issue.record("expected the recorded calibration to run, got \(outcome)")
      return
    }
    #expect(!result.findings.contains { $0.severity.failsGate })
  }

  @Test("a diff splits into per-file sections by new path — catches context from the wrong file")
  func diffSections() {
    let sections = DiffSections.split(
      "diff --git a/A.swift b/A.swift\n+a\ndiff --git a/B/C.swift b/B/C.swift\n+c")
    #expect(sections.map(\.path) == ["A.swift", "B/C.swift"])
    #expect(sections[1].text.hasSuffix("+c"))
  }
}

@Suite("commit comment judge on the Jev backend")
struct JevCommitCommentJudgeTests {
  static let config = """
    \(ProbeRepository.config)

    [judge]
    backend = "jev"
    send_to = "api.typesafe.ai"
    advisory_threshold = 0.6
    block_threshold = 0.9
    """
  static let sentinelKey = "sentinel-jev-key-8f3c1d"
  static let keyed = [JevPin.keyVariable: sentinelKey]
  static let staged = "// Increment the counter by one.\ncount += 1\n"

  static func git(comments: Int = 1) -> FakeGit {
    let content = (0..<comments).map { "// Step \($0) of the walk.\nstep(\($0))" }
      .joined(separator: "\n")
    return FakeGit(staged: [
      "Sources/A.swift": .init(
        content: comments == 1 ? staged : content, addedLines: [1...(2 * comments)])
    ])
  }

  static func review(
    transport: any HTTPTransport, environment: [String: String] = keyed,
    clock: FakeRetryClock = FakeRetryClock(), git: FakeGit = git()
  ) async throws -> String? {
    let repository = try ProbeRepository(config: config)
    defer { repository.remove() }
    let judge = ConfiguredCommitCommentJudge(
      makeJudge: { config, root in
        ConfiguredCommitCommentJudge.judge(
          for: config, root: root, transport: transport, environment: environment, clock: clock)
      },
      git: { _ in git })
    return await judge.review(root: repository.root)
  }

  @Test(
    "a staged comment on a jev config is judged from Jev's captured reply, both questions in 1 request — catches the hook building the Claude judge for a jev repository"
  )
  func replaysCapturedReply() async throws {
    let transport = FakeHTTPTransport([try FakeHTTPTransport.captured("comments")])

    let advice = try #require(try await Self.review(transport: transport))

    #expect(advice.contains("jev/jev-1.13.0"))
    #expect(advice.contains("CUT"))
    #expect(advice.contains("Sources/A.swift:1"))
    #expect(transport.requests.count == 1)
    let request = try #require(transport.requests.first)
    let body = try #require(
      try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
    let questions = try #require(body["questions"] as? [String: Any])
    #expect(questions.keys.sorted() == ["loses-fact", "right-size"])
  }

  @Test(
    "a Jev request that stalls past 15 s reports the judge not run within the hook's budget — catches the hook waiting on the adapter's default 30 s timeout"
  )
  func stallIsNotRun() async throws {
    let transport = StallingTransport(
      stall: .seconds(20), reply: try FakeHTTPTransport.captured("comments"))

    let advice = try #require(try await Self.review(transport: transport))

    #expect(advice.hasPrefix("Comment judge not run"))
    #expect(advice.contains("15 s"))
    #expect(transport.timeouts.allSatisfy { $0 <= .seconds(15) })
    #expect(!transport.timeouts.isEmpty)
  }

  enum Failure: String, CaseIterable, Sendable {
    case missingKey, badKey, stateTooLarge, rateLimited
  }

  @Test(
    "every Jev failure lets the commit through with advice naming why, and never the key — catches a Jev outage silencing the judge or printing TYPESAFE_API_KEY",
    arguments: Failure.allCases)
  func failureIsNamed(_ failure: Failure) async throws {
    let reply: FakeHTTPTransport.Reply
    let environment: [String: String]
    let reason: String
    switch failure {
    case .missingKey:
      (reply, environment, reason) = (
        try FakeHTTPTransport.captured("comments"), [:], "TYPESAFE_API_KEY"
      )
    case .badKey:
      (reply, environment, reason) = (try FakeHTTPTransport.captured("bad-key"), Self.keyed, "401")
    case .stateTooLarge:
      (reply, environment, reason) = (
        try FakeHTTPTransport.captured("oversize"), Self.keyed, "stateTooLarge"
      )
    case .rateLimited:
      (reply, environment, reason) = (
        .response(HTTPResponse(status: 429, body: Data())), Self.keyed, "429"
      )
    }
    let transport = FakeHTTPTransport([reply])

    let advice = try #require(try await Self.review(transport: transport, environment: environment))

    #expect(advice.hasPrefix("Comment judge not run"), "\(failure): \(advice)")
    #expect(advice.contains(reason), "\(failure): \(advice)")
    #expect(!advice.contains(Self.sentinelKey))
  }

  @Test(
    "the capped 6 comments go to Jev in 1 concurrent round, so the hook waits for 1 request, not 2 — catches Jev held to the 4-at-a-time batch meant for claude processes",
    // An under-concurrent batch never fills the barrier; the limit cancels it, which releases it.
    .timeLimit(.minutes(1))
  )
  func capGoesInOneRound() async throws {
    let transport = BarrierTransport(
      expected: ConfiguredCommitCommentJudge.maxComments,
      reply: try FakeHTTPTransport.captured("comments"))

    let advice = try await Self.review(
      transport: transport, git: Self.git(comments: ConfiguredCommitCommentJudge.maxComments + 2))

    #expect(transport.maxInFlight == ConfiguredCommitCommentJudge.maxComments)
    #expect(transport.requestCount == ConfiguredCommitCommentJudge.maxComments)
    #expect(advice.map { !$0.hasPrefix("Comment judge not run") } == true, "\(advice ?? "nil")")
  }
}

/// Answers only when the request's timeout outlasts `stall`, as a server that takes `stall` to
/// reply would; otherwise times out at once, since the fake clock stands in for the wait.
final class StallingTransport: HTTPTransport {
  private let stall: Duration
  private let reply: FakeHTTPTransport.Reply
  private let recorded = Mutex<[Duration]>([])

  init(stall: Duration, reply: FakeHTTPTransport.Reply) {
    self.stall = stall
    self.reply = reply
  }

  var timeouts: [Duration] { recorded.withLock { $0 } }

  func send(_ request: HTTPRequest) async throws(HTTPTransportError) -> HTTPResponse {
    recorded.withLock { $0.append(request.timeout) }
    guard request.timeout > stall else { throw .timedOut }
    switch reply {
    case .response(let response): return response
    case .failure(let error): throw error
    }
  }
}

/// Holds every request until `expected` are in flight at once, then answers them all, so a batch
/// that sends fewer at a time never completes on its own. Cancelling it times out whoever waits.
final class BarrierTransport: HTTPTransport {
  private struct State {
    var waiting: [CheckedContinuation<Bool, Never>] = []
    var inFlight = 0
    var maxInFlight = 0
    var count = 0
    var outcome: Bool?
  }

  private let expected: Int
  private let reply: FakeHTTPTransport.Reply
  private let state = Mutex(State())

  init(expected: Int, reply: FakeHTTPTransport.Reply) {
    self.expected = expected
    self.reply = reply
  }

  var maxInFlight: Int { state.withLock { $0.maxInFlight } }
  var requestCount: Int { state.withLock { $0.count } }

  func send(_ request: HTTPRequest) async throws(HTTPTransportError) -> HTTPResponse {
    let answered = await withTaskCancellationHandler {
      await arrive()
    } onCancel: {
      giveUp()
    }
    state.withLock { $0.inFlight -= 1 }
    guard answered else { throw .timedOut }
    switch reply {
    case .response(let response): return response
    case .failure(let error): throw error
    }
  }

  private func arrive() async -> Bool {
    await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      let (resume, outcome): ([CheckedContinuation<Bool, Never>], Bool) = state.withLock { state in
        state.count += 1
        state.inFlight += 1
        state.maxInFlight = max(state.maxInFlight, state.inFlight)
        if let outcome = state.outcome { return ([continuation], outcome) }
        state.waiting.append(continuation)
        guard state.inFlight >= expected else { return ([], true) }
        state.outcome = true
        defer { state.waiting = [] }
        return (state.waiting, true)
      }
      for waiter in resume { waiter.resume(returning: outcome) }
    }
  }

  private func giveUp() {
    let waiting = state.withLock { state in
      if state.outcome == nil { state.outcome = false }
      defer { state.waiting = [] }
      return state.waiting
    }
    for waiter in waiting { waiter.resume(returning: false) }
  }
}

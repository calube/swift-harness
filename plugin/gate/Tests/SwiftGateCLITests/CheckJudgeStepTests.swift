import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

@testable import SwiftGateCLI

/// `check --tier ready`'s judge step: a changed test the judge flags past `block_threshold` makes
/// T1 RED; one between the thresholds is advisory and leaves T1 as it was. Without the judge the
/// probe's T1 is BLOCKED (reach has no coverage export from the replayed run), never RED, so a
/// RED T1 can only come from the judge.
@Suite("check --tier ready: judge step")
struct CheckJudgeStepTests {
  private static func ready(
    judge: FakeJudge?, config: String = JudgeCommandsTests.enabled,
    reasonJudge: (any Judge)? = nil, secrets: [String] = []
  ) async throws -> (t1: TierResult, judged: [Finding]) {
    let repository = try ProbeRepository(config: config)
    defer { repository.remove() }
    // The fixture's unnamed `@Test` would turn T0 RED and skip T1 before the judge is reached.
    try repository.write(
      JudgeCommandsTests.testFile,
      try String(
        contentsOf: Fixture.gateDirectory.appending(
          path: "Fixtures/swifttest/XUnitProbe/Tests/ProbeTests/PassTests.swift"),
        encoding: .utf8
      ).replacing("@Test func", with: "@Test(\"doubles — catches a wrong product\") func"))
    // Without the probe's deliberately empty target, whose T1 is RED on every run.
    let probe = try ProbeRepository.manifest()
    let swiftPM = try ProbeRepository.swiftPM(
      replaying: "pass",
      manifest: PackageManifest(
        name: probe.name, path: probe.path, localDependencyPaths: probe.localDependencyPaths,
        remoteDependencies: probe.remoteDependencies, products: probe.products,
        targets: probe.targets.filter { $0.name != "EmptyTests" }))
    let git = FakeGit(
      changed: [JudgeCommandsTests.testFile], mergeBase: "base",
      addedSince: [AddedLines(path: JudgeCommandsTests.testFile, ranges: [1...15])])

    let parts = try await CheckRun.run(
      root: repository.root, tier: .ready, base: "origin/main", context: repository.context(),
      dependencies: CheckRun.Dependencies(
        root: repository.root, swiftPM: swiftPM, git: git, formatter: FakeSwiftFormatter(),
        simulator: .fake,
        changedTests: ChangedTestChecks.Environment(
          root: repository.root, git: git, swiftPM: swiftPM,
          scratch: FakeScratchWorktrees(root: repository.root),
          scratchSwiftPM: { _ in swiftPM }),
        judge: judge.map { judge in
          TestJudgeCheck.Dependencies(
            makeJudge: { _ in judge },
            diff: FakeDiff(
              text:
                "diff --git a/\(JudgeCommandsTests.testFile) b/\(JudgeCommandsTests.testFile)\n+@Test\n"
            ), reasonJudge: reasonJudge, secrets: secrets)
        }))
    let t1 = try #require(parts.tiers.first { $0.tier == .t1 })
    return (t1, parts.findings.filter { $0.ruleID.hasPrefix(JudgePolicy.ruleIDPrefix) })
  }

  @Test(
    "a judge answer at or above block_threshold makes T1 RED at ready — catches the judge's blocking verdict dropped by check"
  )
  func blockingAnswerFailsT1() async throws {
    let baseline = try await Self.ready(judge: nil)
    let judge = FakeJudge.answering(flagged: 0.95)

    let judged = try await Self.ready(judge: judge)

    #expect(baseline.t1.verdict != .red)
    #expect(!judge.subjects.isEmpty)
    #expect(judged.judged.contains { $0.severity.failsGate })
    #expect(judged.t1.verdict == .red)
  }

  @Test(
    "an answer between advisory and block thresholds is reported but leaves T1's verdict unchanged — catches advisory findings gating ready"
  )
  func advisoryAnswerDoesNotGate() async throws {
    let baseline = try await Self.ready(judge: nil)
    let judge = FakeJudge.answering(flagged: 0.7)

    let judged = try await Self.ready(judge: judge)

    #expect(!judged.judged.isEmpty)
    #expect(!judged.judged.contains { $0.severity.failsGate })
    #expect(judged.t1.verdict == baseline.t1.verdict)
  }

  // MARK: - Jev

  static let pin = "jev-1.13.0"
  static let jevConfig = JudgeCommandsTests.enabled.replacing(
    "backend = \"claude\"", with: "backend = \"jev\"\nsend_to = \"api.typesafe.ai\"")
  static let jev = JudgeIdentity(backend: "jev", model: pin)
  static let claude = JudgeIdentity(backend: "claude", model: "sonnet")

  /// A judge with `identity` whose flagged option gets `p` on every question.
  static func judge(
    _ identity: JudgeIdentity, flagged p: Double, rationale: String? = "fake"
  ) -> FakeJudge {
    judge(identity, flagged: [:], otherwise: p, rationale: rationale)
  }

  /// A judge with `identity` whose flagged option gets `flagged[question]`, else `otherwise`.
  static func judge(
    _ identity: JudgeIdentity, flagged: [String: Double], otherwise: Double,
    rationale: String? = nil
  ) -> FakeJudge {
    FakeJudge(identity: identity) { subject, questions throws(JudgeError) in
      answers(
        subject, questions, flagged: otherwise, rationale: rationale, overriding: flagged)
    }
  }

  static func answers(
    _ subject: JudgeSubject, _ questions: JudgeQuestionSet, flagged: Double, rationale: String?,
    overriding: [String: Double] = [:]
  ) -> [JudgeAnswer] {
    questions.questions.map { question in
      let p = overriding[question.id] ?? flagged
      let options = question.options
      let flaggedOption: String =
        switch question.flag {
        case .option(let option): option
        case .notDeclaredTier: options.first { $0 != subject.declaredTier } ?? options[0]
        }
      let rest = options.filter { $0 != flaggedOption }
      var distribution = [flaggedOption: p]
      for option in rest { distribution[option] = (1 - p) / Double(rest.count) }
      return JudgeAnswer(question: question.id, distribution: distribution, rationale: rationale)
    }
  }

  static func finding(_ question: String, in judged: [Finding]) throws -> Finding {
    try #require(judged.first { $0.ruleID == JudgePolicy.ruleIDPrefix + question })
  }

  static func findings(_ question: String, in judged: [Finding]) -> [Finding] {
    judged.filter { $0.ruleID == JudgePolicy.ruleIDPrefix + question }
  }

  /// The question ids of each set a judge was asked, in order, and each set's versioned id.
  final class Asked: Sendable {
    private let sets = Mutex<[[String]]>([])
    private let ids = Mutex<[String]>([])

    func record(_ questions: JudgeQuestionSet) {
      sets.withLock { $0.append(questions.questions.map(\.id)) }
      ids.withLock { $0.append(questions.versionedID) }
    }

    var all: [[String]] { sets.withLock { $0 } }
    var versions: Set<String> { Set(ids.withLock { $0 }) }
  }

  /// A Jev judge like ``judge(_:flagged:otherwise:rationale:)`` that records what it was asked.
  static func jevJudge(
    flagged: [String: Double], otherwise: Double, asked: Asked
  ) -> FakeJudge {
    FakeJudge(identity: jev) { subject, questions throws(JudgeError) in
      asked.record(questions)
      return answers(
        subject, questions, flagged: otherwise, rationale: nil, overriding: flagged)
    }
  }

  /// Claude: `p` on the flagged option of whatever it's asked, with `rationale`.
  static func reasonJudge(flagged p: Double, rationale: String, asked: Asked) -> FakeJudge {
    FakeJudge(identity: claude) { subject, questions throws(JudgeError) in
      asked.record(questions)
      return answers(subject, questions, flagged: p, rationale: rationale)
    }
  }

  /// A Claude judge that fails every call with `error`.
  static func failingReasonJudge(_ error: JudgeError, asked: Asked) -> FakeJudge {
    FakeJudge(identity: claude) { _, questions throws(JudgeError) in
      asked.record(questions)
      throw error
    }
  }

  // MARK: - A Jev block and Claude's reason for it

  @Test(
    "Jev at 0.95 on fails-if-broken is major and makes ready RED with no calibration files, after 1 Claude call for its reason and none to answer, even when Claude says 0.1 — catches a Jev block held back or overruled"
  )
  func jevBlocksWithClaudesReason() async throws {
    let asked = Asked()

    let judged = try await Self.ready(
      judge: Self.judge(Self.jev, flagged: ["fails-if-broken": 0.95], otherwise: 0.1),
      config: Self.jevConfig,
      reasonJudge: Self.reasonJudge(
        flagged: 0.1, rationale: "the assertion compares the doubled value", asked: asked))

    let blocks = Self.findings("fails-if-broken", in: judged.judged)
    #expect(!blocks.isEmpty)
    for finding in blocks {
      #expect(finding.severity == .major)
      #expect(finding.message.contains("(p=0.95, jev/\(Self.pin))"))
      #expect(finding.message.contains("reason from claude/sonnet (claude p=0.10)"))
      #expect(finding.failureScenario == "the assertion compares the doubled value")
    }
    #expect(asked.all == Array(repeating: ["fails-if-broken"], count: blocks.count))
    #expect(judged.judged.allSatisfy { $0.ruleID == "judge.fails-if-broken" })
    #expect(judged.t1.verdict == .red)
  }

  @Test(
    "minor Jev findings that stand keep the template reason and ask Claude nothing, while the block beside them asks it — catches a Claude call on every flag"
  )
  func minorJevFindingsAskNoReason() async throws {
    let asked = Asked()

    // 0.85 lies above the band and below block_threshold, so Jev's answer stands as advisory.
    let judged = try await Self.ready(
      judge: Self.judge(
        Self.jev, flagged: ["fails-if-broken": 0.99, "tier": 0.1], otherwise: 0.85),
      config: Self.jevConfig,
      reasonJudge: Self.reasonJudge(flagged: 0.9, rationale: "a reason", asked: asked))

    let blocking = judged.judged.filter { $0.severity == .major }
    #expect(!blocking.isEmpty)
    #expect(asked.all == Array(repeating: ["fails-if-broken"], count: blocking.count))
    let minor = judged.judged.filter { $0.severity == .minor }
    #expect(!Self.findings("asserts-implementation", in: minor).isEmpty)
    for finding in minor {
      #expect(finding.failureScenario == nil)
      #expect(finding.message.contains("(p=0.85, jev/\(Self.pin))"))
      #expect(!finding.message.contains("claude"))
    }
  }

  enum ReasonFailure: String, CaseIterable, Sendable {
    case notOnPath, timeout, backendError

    var error: JudgeError {
      switch self {
      case .notOnPath:
        .process(.launchFailed(executable: "claude", reason: "not found on PATH /usr/bin"))
      case .timeout:
        .process(
          .timedOut(
            executable: "claude", after: .seconds(180), stdout: CapturedStream(),
            stderr: CapturedStream()))
      case .backendError: .backend("overloaded")
      }
    }

    var why: String {
      switch self {
      case .notOnPath: "claude could not start: not found on PATH /usr/bin"
      case .timeout: "claude timed out after 180 s"
      case .backendError: "claude reported an error: overloaded"
      }
    }
  }

  @Test(
    "when Claude can't write the reason, the Jev block stays major and failureScenario says why Claude's reason is missing — catches a lost block or a silent missing reason",
    arguments: ReasonFailure.allCases)
  func failingClaudeLeavesJevBlockWithMissingReason(_ failure: ReasonFailure) async throws {
    let judged = try await Self.ready(
      judge: Self.judge(Self.jev, flagged: ["fails-if-broken": 0.99], otherwise: 0.01),
      config: Self.jevConfig,
      reasonJudge: Self.failingReasonJudge(failure.error, asked: Asked()))

    let blocks = Self.findings("fails-if-broken", in: judged.judged)
    #expect(!blocks.isEmpty)
    for finding in blocks {
      #expect(finding.severity == .major)
      #expect(finding.failureScenario == JudgeBlockReason.missingPrefix + failure.why)
      #expect(finding.message.contains("(p=0.99, jev/\(Self.pin))"))
    }
    #expect(judged.t1.verdict == .red)
  }

  @Test(
    "with no Claude judge at all, the Jev block stays major and says no Claude judge was available — catches a nil judge read as a reason"
  )
  func missingReasonJudgeLeavesJevBlockWithMissingReason() async throws {
    let judged = try await Self.ready(
      judge: Self.judge(Self.jev, flagged: 0.99, rationale: nil), config: Self.jevConfig)

    let blocks = Self.findings("fails-if-broken", in: judged.judged)
    #expect(!blocks.isEmpty)
    for finding in blocks {
      #expect(finding.severity == .major)
      #expect(
        finding.failureScenario == JudgeBlockReason.missingPrefix + "no Claude judge is available")
    }
  }

  @Test(
    "a Claude-backend block keeps Claude's own rationale and asks the reason judge nothing, while a Jev block asks it — catches asking Claude twice for its reason"
  )
  func claudeBlockMakesNoSecondCall() async throws {
    let claudeAsked = Asked()
    let jevAsked = Asked()

    let claude = try await Self.ready(
      judge: Self.judge(Self.claude, flagged: 0.99, rationale: "Claude's own reason"),
      reasonJudge: Self.reasonJudge(flagged: 0.5, rationale: "a second reason", asked: claudeAsked))
    let jev = try await Self.ready(
      judge: Self.judge(Self.jev, flagged: ["fails-if-broken": 0.99], otherwise: 0.01),
      config: Self.jevConfig,
      reasonJudge: Self.reasonJudge(flagged: 0.5, rationale: "a second reason", asked: jevAsked))

    let blocks = claude.judged.filter { $0.severity == .major }
    #expect(!blocks.isEmpty)
    for finding in blocks {
      #expect(finding.failureScenario == "Claude's own reason")
      #expect(!finding.message.contains("claude p="))
    }
    #expect(claudeAsked.all.isEmpty)
    #expect(!jevAsked.all.isEmpty)
    #expect(jev.t1.verdict == .red)
  }

  @Test(
    "the live Claude judge runs claude without the Jev key, and a failure that echoes the key reaches no reason or escalation note — catches the key reaching Claude or a finding"
  )
  func liveReasonJudgeNeverCarriesTheKey() async throws {
    let cache = FileManager.default.temporaryDirectory.appending(
      path: "judge-reason-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: cache) }
    let key = "tsk-live-secret-0123456789"
    let runner = FakeProcessRunner { invocation throws(ProcessRunnerError) in
      throw .launchFailed(executable: invocation.executable, reason: "no claude; saw \(key)")
    }

    let judged = try await Self.ready(
      judge: Self.judge(
        Self.jev, flagged: ["fails-if-broken": 0.99, "asserts-implementation": 0.7],
        otherwise: 0.01),
      config: Self.jevConfig,
      reasonJudge: JudgeBlockReason.liveJudge(root: cache, runner: runner), secrets: [key])

    let invocation = try #require(runner.invocations.first)
    #expect(invocation.environmentOverlay.keys.contains("TYPESAFE_API_KEY"))
    #expect(invocation.environmentOverlay["TYPESAFE_API_KEY"] == .some(nil))
    let blocks = Self.findings("fails-if-broken", in: judged.judged)
    #expect(!blocks.isEmpty)
    for finding in blocks {
      #expect(finding.severity == .major)
      #expect(finding.failureScenario?.hasPrefix(JudgeBlockReason.missingPrefix) == true)
    }
    // asserts-implementation escalated to the same failing claude, whose error echoes the key.
    let escalated = try Self.finding("asserts-implementation", in: judged.judged)
    #expect(escalated.message.contains("which failed: claude could not start"))
    #expect(!judged.judged.contains { $0.message.contains(key) })
    #expect(!judged.judged.contains { $0.failureScenario?.contains(key) == true })
  }

  // MARK: - The cascade to Claude

  @Test(
    "Jev at p_no 0.5 escalates both blocking questions to Claude, whose 0.95 makes ready RED under claude/<model> with Claude's rationale after 1 call per test and no reason call — catches a second reason call on an escalated block"
  )
  func uncertainJevEscalatesToClaude() async throws {
    let asked = Asked()
    let jev = Self.judge(Self.jev, flagged: 0.5, rationale: nil)

    let judged = try await Self.ready(
      judge: jev, config: Self.jevConfig,
      reasonJudge: Self.reasonJudge(
        flagged: 0.95, rationale: "the doubled value is never compared", asked: asked))

    let blocking = judged.judged.filter { $0.severity == .major }
    #expect(
      Set(blocking.map(\.ruleID)) == ["judge.fails-if-broken", "judge.asserts-implementation"])
    for finding in blocking {
      #expect(finding.message.contains("(p=0.95, claude/sonnet)"))
      #expect(!finding.message.contains("jev/"))
      #expect(!finding.message.contains("claude p="))
      #expect(finding.failureScenario == "the doubled value is never compared")
    }
    #expect(!jev.subjects.isEmpty)
    #expect(
      asked.all
        == Array(
          repeating: ["fails-if-broken", "asserts-implementation"], count: jev.subjects.count))
    #expect(judged.t1.verdict == .red)
  }

  @Test(
    "Jev at 0.1 on every question asks Claude nothing and reports nothing — catches escalating every question"
  )
  func confidentJevAsksClaudeNothing() async throws {
    let asked = Asked()
    let jevAsked = Asked()

    let judged = try await Self.ready(
      judge: Self.jevJudge(flagged: [:], otherwise: 0.1, asked: jevAsked), config: Self.jevConfig,
      reasonJudge: Self.reasonJudge(flagged: 0.95, rationale: "a reason", asked: asked))

    #expect(jevAsked.versions == ["test-quality@2-jev"])
    #expect(asked.all.isEmpty)
    #expect(judged.judged.isEmpty)
  }

  @Test(
    "when Claude fails an uncertain escalation, Jev's answer stays minor with a note naming why, and ready isn't RED — catches an uncertain Jev answer blocking when Claude is down"
  )
  func failingEscalationLeavesJevMinor() async throws {
    let judged = try await Self.ready(
      judge: Self.judge(Self.jev, flagged: ["asserts-implementation": 0.7], otherwise: 0.1),
      config: Self.jevConfig,
      reasonJudge: Self.failingReasonJudge(.backend("overloaded"), asked: Asked()))

    let escalated = try Self.finding("asserts-implementation", in: judged.judged)
    #expect(escalated.severity == .minor)
    #expect(
      escalated.message.contains(
        "(p=0.70, jev/\(Self.pin)); escalated to claude as uncertain, which failed: claude "
          + "reported an error: overloaded"))
    #expect(judged.judged.allSatisfy { $0.severity == .minor })
    #expect(judged.t1.verdict != .red)
  }

  @Test(
    "name-specificity and tier at 0.5 ask Claude nothing — catches an advisory question escalated"
  )
  func advisoryQuestionsNeverEscalate() async throws {
    let asked = Asked()
    let jevAsked = Asked()

    _ = try await Self.ready(
      judge: Self.jevJudge(
        flagged: ["name-specificity": 0.5, "tier": 0.5], otherwise: 0.1, asked: jevAsked),
      config: Self.jevConfig,
      reasonJudge: Self.reasonJudge(flagged: 0.95, rationale: "a reason", asked: asked))

    #expect(jevAsked.versions == ["test-quality@2-jev"])
    #expect(asked.all.isEmpty)
  }
}

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
    judge: FakeJudge?, config: String = JudgeCommandsTests.enabled, harnessRoot: URL? = nil,
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
            ), harnessRoot: harnessRoot, reasonJudge: reasonJudge, secrets: secrets)
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

  // MARK: - Jev and its block calibration

  static let pin = "jev-1.13.0"
  static let jevConfig = JudgeCommandsTests.enabled.replacing(
    "backend = \"claude\"", with: "backend = \"jev\"\nsend_to = \"api.typesafe.ai\"")
  /// Ids in the report split: their SHA-256 starts at or above 0x55 (computed with Python's hashlib).
  static let reportIDs = [
    0, 1, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 18, 19, 20, 21, 22, 23, 24, 29, 30, 31, 32,
    33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 44,
  ].map { "case-\($0)" }

  /// A judge with `identity` whose flagged option gets `p` on every question.
  static func judge(
    _ identity: JudgeIdentity, flagged p: Double, rationale: String? = "fake"
  ) -> FakeJudge {
    FakeJudge(identity: identity) { subject, questions throws(JudgeError) in
      answers(subject, questions, flagged: p, rationale: rationale)
    }
  }

  static func answers(
    _ subject: JudgeSubject, _ questions: JudgeQuestionSet, flagged p: Double, rationale: String?
  ) -> [JudgeAnswer] {
    questions.questions.map { question in
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

  /// A harness root holding 30 person labels for `fails-if-broken` only (10 where it should flag),
  /// Claude's recording, and, unless `jevModel` is `nil`, a jev recording from that model. Both
  /// recordings answer every case correctly.
  static func harnessRoot(jevModel: String?) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "judge-harness-\(UUID().uuidString)", directoryHint: .isDirectory)
    let directory = root.appending(path: JudgeCalibrationFiles.directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let cases = reportIDs.prefix(30).enumerated().map { index, id in (id: id, positive: index < 10)
    }
    let set = JudgeCalibrationSet(
      questionSet: "test-quality@1",
      cases: cases.map {
        .init(
          id: $0.id, label: $0.positive ? .useless : .good, declaredTier: "T1",
          expected: ["fails-if-broken": $0.positive ? "no" : "yes"], labeller: .person)
      })
    func recording(_ identity: JudgeIdentity) -> JudgeRecording {
      JudgeRecording(
        questionSet: "test-quality@1", identity: identity,
        answers: Dictionary(
          uniqueKeysWithValues: cases.map {
            let p = $0.positive ? 0.99 : 0.01
            return (
              $0.id,
              [
                JudgeAnswer(
                  question: "fails-if-broken", distribution: ["no": p, "yes": 1 - p],
                  rationale: nil)
              ]
            )
          }))
    }
    try JSONEncoder().encode(set).write(
      to: directory.appending(path: JudgeCalibrationFiles.labelsFile))
    try JSONEncoder().encode(
      recording(JudgeIdentity(backend: "claude", model: "claude-sonnet-5-5"))
    ).write(to: directory.appending(path: JudgeCalibrationFiles.recordingFile(for: .claude)))
    if let jevModel {
      try JSONEncoder().encode(recording(JudgeIdentity(backend: "jev", model: jevModel))).write(
        to: directory.appending(path: JudgeCalibrationFiles.recordingFile(for: .jev)))
    }
    return root
  }

  static func finding(_ question: String, in judged: [Finding]) throws -> Finding {
    try #require(judged.first { $0.ruleID == JudgePolicy.ruleIDPrefix + question })
  }

  @Test(
    "with no jev recording, a jev answer at p=0.99 is minor naming no recording and ready stays green, while claude's with no files at all is major — catches a Jev block with no calibration, or Claude's blocks downgraded"
  )
  func jevWithoutRecordingIsAdvisory() async throws {
    let root = try Self.harnessRoot(jevModel: nil)
    defer { try? FileManager.default.removeItem(at: root) }

    let jev = try await Self.ready(
      judge: Self.judge(JudgeIdentity(backend: "jev", model: Self.pin), flagged: 0.99),
      config: Self.jevConfig, harnessRoot: root)
    let claude = try await Self.ready(
      judge: Self.judge(JudgeIdentity(backend: "claude", model: "sonnet"), flagged: 0.99))

    let advisory = try Self.finding("fails-if-broken", in: jev.judged)
    #expect(advisory.severity == .minor)
    #expect(
      advisory.message.contains(
        "advisory: jev has no passing block calibration for fails-if-broken on \(Self.pin): "))
    #expect(advisory.message.contains("no recording"))
    #expect(jev.t1.verdict != .red)
    #expect(try Self.finding("fails-if-broken", in: claude.judged).severity == .major)
    #expect(claude.t1.verdict == .red)
  }

  @Test(
    "a passing calibration for fails-if-broken at the pin makes it major and ready RED, while asserts-implementation with no labels stays minor — catches a calibrated Jev never blocking, or one question's calibration unlocking another"
  )
  func jevCalibratedQuestionBlocks() async throws {
    let root = try Self.harnessRoot(jevModel: Self.pin)
    defer { try? FileManager.default.removeItem(at: root) }

    let judged = try await Self.ready(
      judge: Self.judge(JudgeIdentity(backend: "jev", model: Self.pin), flagged: 0.99),
      config: Self.jevConfig, harnessRoot: root)

    #expect(try Self.finding("fails-if-broken", in: judged.judged).severity == .major)
    let other = try Self.finding("asserts-implementation", in: judged.judged)
    #expect(other.severity == .minor)
    #expect(other.message.contains("0 of 30"))
    #expect(judged.t1.verdict == .red)
  }

  @Test(
    "a recording from jev-1.12.0 with a jev-1.13.0 pin is minor naming both models — catches a stale calibration that still blocks"
  )
  func jevStaleRecordingIsAdvisory() async throws {
    let root = try Self.harnessRoot(jevModel: "jev-1.12.0")
    defer { try? FileManager.default.removeItem(at: root) }

    let judged = try await Self.ready(
      judge: Self.judge(JudgeIdentity(backend: "jev", model: Self.pin), flagged: 0.99),
      config: Self.jevConfig, harnessRoot: root)

    let advisory = try Self.finding("fails-if-broken", in: judged.judged)
    #expect(advisory.severity == .minor)
    #expect(advisory.message.contains("jev-1.12.0"))
    #expect(advisory.message.contains(Self.pin))
    #expect(judged.t1.verdict != .red)
  }

  // MARK: - Claude's reason on a blocking Jev finding

  static let jev = JudgeIdentity(backend: "jev", model: pin)
  static let claude = JudgeIdentity(backend: "claude", model: "sonnet")

  /// The question ids of each set a judge was asked, in order.
  final class Asked: Sendable {
    private let sets = Mutex<[[String]]>([])

    func record(_ questions: JudgeQuestionSet) {
      sets.withLock { $0.append(questions.questions.map(\.id)) }
    }

    var all: [[String]] { sets.withLock { $0 } }
  }

  /// Claude writing reasons: `p` on the flagged option of whatever it's asked, with `rationale`.
  static func reasonJudge(flagged p: Double, rationale: String, asked: Asked) -> FakeJudge {
    FakeJudge(identity: claude) { subject, questions throws(JudgeError) in
      asked.record(questions)
      return answers(subject, questions, flagged: p, rationale: rationale)
    }
  }

  /// A reason judge that fails every call with `error`.
  static func failingReasonJudge(_ error: JudgeError, asked: Asked) -> FakeJudge {
    FakeJudge(identity: claude) { _, questions throws(JudgeError) in
      asked.record(questions)
      throw error
    }
  }

  static func findings(_ question: String, in judged: [Finding]) -> [Finding] {
    judged.filter { $0.ruleID == JudgePolicy.ruleIDPrefix + question }
  }

  @Test(
    "a calibrated Jev block carries the reason judge's rationale with Jev's and Claude's p, from 1 call per blocking finding asking only its question — catches a Jev block with no reason"
  )
  func calibratedJevBlockCarriesClaudesReason() async throws {
    let root = try Self.harnessRoot(jevModel: Self.pin)
    defer { try? FileManager.default.removeItem(at: root) }
    let asked = Asked()

    let judged = try await Self.ready(
      judge: Self.judge(Self.jev, flagged: 0.99, rationale: nil), config: Self.jevConfig,
      harnessRoot: root,
      reasonJudge: Self.reasonJudge(
        flagged: 0.93, rationale: "doubling with the wrong factor still passes", asked: asked))

    let blocking = judged.judged.filter { $0.severity == .major }
    #expect(!blocking.isEmpty)
    for finding in blocking {
      #expect(finding.failureScenario == "doubling with the wrong factor still passes")
      #expect(finding.message.contains("p=0.99, jev/\(Self.pin)"))
      #expect(finding.message.contains("claude p=0.93"))
    }
    #expect(asked.all == Array(repeating: ["fails-if-broken"], count: blocking.count))
    #expect(judged.t1.verdict == .red)
  }

  @Test(
    "a reason judge answering p=0.02 leaves the calibrated Jev block major, with its rationale and p beside Jev's — catches Claude overruling Jev"
  )
  func disagreeingClaudeLeavesJevBlockMajor() async throws {
    let root = try Self.harnessRoot(jevModel: Self.pin)
    defer { try? FileManager.default.removeItem(at: root) }

    let judged = try await Self.ready(
      judge: Self.judge(Self.jev, flagged: 0.99, rationale: nil), config: Self.jevConfig,
      harnessRoot: root,
      reasonJudge: Self.reasonJudge(
        flagged: 0.02, rationale: "the assertion compares the doubled value", asked: Asked()))

    let blocks = Self.findings("fails-if-broken", in: judged.judged)
    #expect(!blocks.isEmpty)
    for finding in blocks {
      #expect(finding.severity == .major)
      #expect(finding.failureScenario == "the assertion compares the doubled value")
      #expect(finding.message.contains("p=0.99, jev/\(Self.pin)"))
      #expect(finding.message.contains("claude p=0.02"))
    }
    #expect(judged.t1.verdict == .red)
  }

  @Test(
    "minor Jev findings keep the template reason and ask the reason judge nothing, while the block beside them asks it — catches a Claude call on every flag"
  )
  func minorJevFindingsAskNoReason() async throws {
    let calibratedRoot = try Self.harnessRoot(jevModel: Self.pin)
    let uncalibratedRoot = try Self.harnessRoot(jevModel: nil)
    defer {
      try? FileManager.default.removeItem(at: calibratedRoot)
      try? FileManager.default.removeItem(at: uncalibratedRoot)
    }
    let asked = Asked()
    let unasked = Asked()

    let calibrated = try await Self.ready(
      judge: Self.judge(Self.jev, flagged: 0.99, rationale: nil), config: Self.jevConfig,
      harnessRoot: calibratedRoot,
      reasonJudge: Self.reasonJudge(flagged: 0.9, rationale: "a reason", asked: asked))
    let uncalibrated = try await Self.ready(
      judge: Self.judge(Self.jev, flagged: 0.99, rationale: nil), config: Self.jevConfig,
      harnessRoot: uncalibratedRoot,
      reasonJudge: Self.reasonJudge(flagged: 0.9, rationale: "a reason", asked: unasked))

    let blocking = calibrated.judged.filter { $0.severity == .major }
    #expect(!blocking.isEmpty)
    #expect(asked.all == Array(repeating: ["fails-if-broken"], count: blocking.count))
    let minor = calibrated.judged.filter { $0.severity == .minor } + uncalibrated.judged
    #expect(!Self.findings("asserts-implementation", in: minor).isEmpty)
    for finding in minor {
      #expect(finding.severity == .minor)
      #expect(finding.failureScenario == nil)
      #expect(finding.message.contains("(p=0.99, jev/\(Self.pin))"))
      #expect(!finding.message.contains("claude p="))
    }
    #expect(unasked.all.isEmpty)
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
    "when the reason judge fails, the calibrated Jev block stays major and failureScenario says why Claude's reason is missing — catches a lost block or a silent missing reason",
    arguments: ReasonFailure.allCases)
  func failingClaudeLeavesJevBlockWithMissingReason(_ failure: ReasonFailure) async throws {
    let root = try Self.harnessRoot(jevModel: Self.pin)
    defer { try? FileManager.default.removeItem(at: root) }

    let judged = try await Self.ready(
      judge: Self.judge(Self.jev, flagged: 0.99, rationale: nil), config: Self.jevConfig,
      harnessRoot: root, reasonJudge: Self.failingReasonJudge(failure.error, asked: Asked()))

    let blocks = Self.findings("fails-if-broken", in: judged.judged)
    #expect(!blocks.isEmpty)
    for finding in blocks {
      #expect(finding.severity == .major)
      #expect(finding.failureScenario == JudgeBlockReason.missingPrefix + failure.why)
      #expect(finding.message.contains("p=0.99, jev/\(Self.pin)"))
    }
    #expect(judged.t1.verdict == .red)
  }

  @Test(
    "with no reason judge at all, the calibrated Jev block stays major and says no Claude judge was available — catches a nil judge read as a reason"
  )
  func missingReasonJudgeLeavesJevBlockWithMissingReason() async throws {
    let root = try Self.harnessRoot(jevModel: Self.pin)
    defer { try? FileManager.default.removeItem(at: root) }

    let judged = try await Self.ready(
      judge: Self.judge(Self.jev, flagged: 0.99, rationale: nil), config: Self.jevConfig,
      harnessRoot: root)

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
    let root = try Self.harnessRoot(jevModel: Self.pin)
    defer { try? FileManager.default.removeItem(at: root) }
    let claudeAsked = Asked()
    let jevAsked = Asked()

    let claude = try await Self.ready(
      judge: Self.judge(Self.claude, flagged: 0.99, rationale: "Claude's own reason"),
      reasonJudge: Self.reasonJudge(flagged: 0.5, rationale: "a second reason", asked: claudeAsked))
    let jev = try await Self.ready(
      judge: Self.judge(Self.jev, flagged: 0.99, rationale: nil), config: Self.jevConfig,
      harnessRoot: root,
      reasonJudge: Self.reasonJudge(flagged: 0.5, rationale: "a second reason", asked: jevAsked))

    let blocks = claude.judged.filter { $0.severity == .major }
    #expect(!blocks.isEmpty)
    for finding in blocks {
      #expect(finding.failureScenario == "Claude's own reason")
      #expect(!finding.message.contains("claude p="))
    }
    #expect(claudeAsked.all.isEmpty)
    #expect(!jevAsked.all.isEmpty)
  }

  @Test(
    "the live reason judge runs claude without the Jev key, and a failure that echoes the key never puts it in a reason — catches the key reaching Claude or a finding"
  )
  func liveReasonJudgeNeverCarriesTheKey() async throws {
    let root = try Self.harnessRoot(jevModel: Self.pin)
    let cache = FileManager.default.temporaryDirectory.appending(
      path: "judge-reason-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: cache)
    }
    let key = "tsk-live-secret-0123456789"
    let runner = FakeProcessRunner { invocation throws(ProcessRunnerError) in
      throw .launchFailed(executable: invocation.executable, reason: "no claude; saw \(key)")
    }

    let judged = try await Self.ready(
      judge: Self.judge(Self.jev, flagged: 0.99, rationale: nil), config: Self.jevConfig,
      harnessRoot: root, reasonJudge: JudgeBlockReason.liveJudge(root: cache, runner: runner),
      secrets: [key])

    let invocation = try #require(runner.invocations.first)
    #expect(invocation.environmentOverlay.keys.contains("TYPESAFE_API_KEY"))
    #expect(invocation.environmentOverlay["TYPESAFE_API_KEY"] == .some(nil))
    let blocks = Self.findings("fails-if-broken", in: judged.judged)
    #expect(!blocks.isEmpty)
    for finding in blocks {
      #expect(finding.severity == .major)
      #expect(finding.failureScenario?.hasPrefix(JudgeBlockReason.missingPrefix) == true)
      #expect(finding.failureScenario?.contains(key) == false)
      #expect(!finding.message.contains(key))
    }
  }
}

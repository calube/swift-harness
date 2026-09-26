import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateRules
import SwiftGateTestSupport
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
        contentsOf: Fixture.pluginRoot.appending(path: "gate/Fixtures/judge/labels.json")))
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
      harnessRoot: Fixture.pluginRoot, judge: oracle, record: false)
    let bad = await JudgeSelfTest.run(
      harnessRoot: Fixture.pluginRoot, judge: FakeJudge.answering(flagged: 0.9), record: false)

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
      harnessRoot: Fixture.pluginRoot, judge: nil, record: false)
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

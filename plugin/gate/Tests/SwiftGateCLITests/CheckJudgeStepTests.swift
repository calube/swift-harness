import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// `check --tier ready`'s judge step: a changed test the judge flags past `block_threshold` makes
/// T1 RED; one between the thresholds is advisory and leaves T1 as it was. Without the judge the
/// probe's T1 is BLOCKED (reach has no coverage export from the replayed run), never RED, so a
/// RED T1 can only come from the judge.
@Suite("check --tier ready: judge step")
struct CheckJudgeStepTests {
  private static func ready(
    judge: FakeJudge?, config: String = JudgeCommandsTests.enabled, harnessRoot: URL? = nil
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
            ), harnessRoot: harnessRoot)
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
    "backend = \"claude\"", with: "backend = \"jev\"")
  /// Ids in the report split: their SHA-256 starts at or above 0x55 (computed with Python's hashlib).
  static let reportIDs = [
    0, 1, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 18, 19, 20, 21, 22, 23, 24, 29, 30, 31, 32,
    33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 44,
  ].map { "case-\($0)" }

  /// A judge with `identity` whose flagged option gets `p` on every question.
  static func judge(_ identity: JudgeIdentity, flagged p: Double) -> FakeJudge {
    FakeJudge(identity: identity) { subject, questions throws(JudgeError) in
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
        return JudgeAnswer(question: question.id, distribution: distribution, rationale: "fake")
      }
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
}

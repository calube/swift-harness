import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

@testable import SwiftGateCLI

@Suite("judge bench and bench-render")
struct JudgeBenchCommandTests {
  /// Ids whose SHA-256 starts at or above 0x55, so every one is in the report split.
  static let caseIDs = [0, 1, 4, 5].map { "case-\($0)" }

  /// Answers every question with `flagged` on the flagged option, counts its calls, and names the
  /// served model `served(call)` for the 0-based call number.
  final class ServingJudge: Judge {
    let identity: JudgeIdentity
    let flagged: Double
    let served: @Sendable (Int) -> String?
    private let calls = Mutex(0)

    init(
      _ backend: String, _ model: String, flagged: Double = 0.8,
      served: @escaping @Sendable (Int) -> String? = { _ in nil }
    ) {
      identity = JudgeIdentity(backend: backend, model: model)
      self.flagged = flagged
      self.served = served
    }

    var count: Int { calls.withLock { $0 } }

    func answer(_ subject: JudgeSubject, questions: JudgeQuestionSet) async throws(JudgeError)
      -> [JudgeAnswer]
    {
      try await measuredAnswer(subject, questions: questions).answers
    }

    func measuredAnswer(_ subject: JudgeSubject, questions: JudgeQuestionSet)
      async throws(JudgeError) -> JudgeReply
    {
      let call = calls.withLock { value in
        defer { value += 1 }
        return value
      }
      return JudgeReply(
        answers: questions.questions.map { question in
          let flag: String =
            switch question.flag {
            case .option(let option): option
            case .notDeclaredTier: "T2"
            }
          let other = question.options.first { $0 != flag } ?? flag
          return JudgeAnswer(
            question: question.id, distribution: [flag: flagged, other: 1 - flagged],
            rationale: nil)
        },
        usage: JudgeUsage(
          inputTokens: 100, outputTokens: 10, costUSD: 0.01, wallMilliseconds: 5,
          servedModel: served(call)))
    }
  }

  /// Building a judge never runs a process.
  static let noProcess = FakeProcessRunner { invocation throws(ProcessRunnerError) in
    throw .launchFailed(executable: invocation.executable, reason: "no process in this test")
  }

  static func datasetObject(labeller: String = "agent") -> [String: Any] {
    [
      "schemaVersion": 1, "id": "four", "questionSet": "test-quality@1",
      "cases": caseIDs.enumerated().map { index, id in
        [
          "id": id, "source": "func test\(index)() {}", "context": "diff \(index)",
          "declaredTier": "T1",
          "labels": [
            "test-quality@1": [
              "labeller": labeller,
              "expected": [
                "fails-if-broken": index.isMultiple(of: 2) ? "no" : "yes",
                "asserts-implementation": index.isMultiple(of: 2) ? "yes" : "no",
              ],
            ]
          ],
        ] as [String: Any]
      },
    ]
  }

  static func dataset() throws -> JudgeDataset {
    try JudgeDataset.decode(try JSONSerialization.data(withJSONObject: datasetObject()))
  }

  static func plan(
    arms: [String] = ["claude:claude-sonnet-5-5", "jev:jev-1.13.0"], repeats: Int = 3
  ) throws -> JudgeBench.Plan {
    let dataset = try dataset()
    return JudgeBench.Plan(
      dataset: dataset, cases: dataset.cases,
      arms: try arms.map { text in
        let arm = try JudgeBenchmarkArm.parse(text)
        return (arm, try arm.questions(for: dataset))
      }, repeats: repeats, concurrency: 1, threshold: 0.5, purpose: .benchmark)
  }

  static func temporaryRoot() throws -> URL {
    let root = TestTemporaryDirectory.root.appending(
      path: "judge-bench-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  static func options(
    _ dataset: String, arms: [String] = ["claude:claude-sonnet-5-5"], repeats: Int = 3,
    edit: (inout JudgeBench.Options) -> Void = { _ in }
  ) -> JudgeBench.Options {
    var options = JudgeBench.Options(dataset: dataset, arms: arms)
    options.repeats = repeats
    edit(&options)
    return options
  }

  static func refusal<Value>(_ result: Result<Value, JudgeBench.Refusal>) -> JudgeBench.Refusal? {
    guard case .failure(let refusal) = result else { return nil }
    return refusal
  }

  // MARK: - bench

  @Test(
    "2 judges on a 4-case dataset give 3 repeats × 4 cases × 2 arms of raw answers, each call reaching the judge and no cache file — catches repeats served from the cache"
  )
  func runsEveryRepeatAgainstTheBackend() async throws {
    let root = try Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let claude = ServingJudge("claude", "claude-sonnet-5-5", flagged: 0.9) { _ in
      "claude-sonnet-5-5-20260915"
    }
    let jev = ServingJudge("jev", "jev-1.13.0", flagged: 0.2) { _ in "jev-1.13.0" }
    let result = await JudgeBench.run(
      try Self.plan(), judges: [claude, jev], startedAt: Date(timeIntervalSince1970: 0))
    let report = try result.get()
    #expect(claude.count == 12)
    #expect(jev.count == 12)
    #expect(report.arms.count == 2)
    for arm in report.arms {
      #expect(arm.repeats.count == 3)
      #expect(arm.repeats.allSatisfy { $0.keys.sorted() == Self.caseIDs })
      #expect(arm.repeats.allSatisfy { $0.values.allSatisfy { $0.count == 1 } })
    }
    #expect(
      report.arms[0].identity
        == JudgeBenchmarkIdentity(
          backend: "claude", requestedModel: "claude-sonnet-5-5",
          servedModel: "claude-sonnet-5-5-20260915"))
    #expect(report.startedAt == "1970-01-01T00:00:00Z")
    #expect(report.dataset.id == "four")
    #expect(report.cases.map(\.labeller) == Array(repeating: .agent, count: 4))
    try JudgeBenchmarkReport.decode(report.json).verify()

    let live = JudgeBench.liveJudge(
      try JudgeBenchmarkArm.parse("claude:claude-sonnet-5-5"), runner: Self.noProcess,
      environment: [:])
    #expect(!(live is CachingJudge))
    #expect(live.identity == JudgeIdentity(backend: "claude", model: "claude-sonnet-5-5"))
    let liveJev = JudgeBench.liveJudge(
      try JudgeBenchmarkArm.parse("jev:jev-1.13.0"), runner: Self.noProcess, environment: [:])
    #expect(!(liveJev is CachingJudge))
    #expect(liveJev.identity == JudgeIdentity(backend: "jev", model: "jev-1.13.0"))
    #expect(
      !FileManager.default.fileExists(
        atPath: FileJudgeCache(worktree: root).directory.path))
  }

  @Test(
    "a served model that changes on repeat 2 fails the run with exit 3 naming both models — catches a result that mixes 2 models"
  )
  func servedModelChangeFails() async throws {
    let claude = ServingJudge("claude", "claude-sonnet-5-5") { call in
      call < 4 ? "claude-sonnet-5-5-a" : "claude-sonnet-5-5-b"
    }
    let result = await JudgeBench.run(
      try Self.plan(arms: ["claude:claude-sonnet-5-5"]), judges: [claude], startedAt: Date())
    let refusal = try #require(Self.refusal(result))
    #expect(refusal.status == 3)
    #expect(refusal.message.contains("claude-sonnet-5-5-a"))
    #expect(refusal.message.contains("claude-sonnet-5-5-b"))
    #expect(refusal.message.contains("repeat 2"))
  }

  @Test(
    "Jev on test-quality@2-jev is asked the rendered set and scored on @1's labels — catches the native arm scored against no labels"
  )
  func nativeArmScoresOnBaseLabels() async throws {
    let asked = Mutex<[String]>([])
    let jev = FakeJudge(identity: JudgeIdentity(backend: "jev", model: "jev-1.13.0")) {
      _, questions throws(JudgeError) in
      asked.withLock { $0.append(questions.versionedID) }
      return questions.questions.map {
        JudgeAnswer(
          question: $0.id,
          distribution: Dictionary(uniqueKeysWithValues: $0.options.map { ($0, 0.5) }),
          rationale: nil)
      }
    }
    let plan = try Self.plan(arms: ["jev:jev-1.13.0#test-quality@2-jev"])
    let report = try await JudgeBench.run(plan, judges: [jev], startedAt: Date()).get()
    #expect(Set(asked.withLock { $0 }) == ["test-quality@2-jev"])
    #expect(report.arms[0].questionSet == "test-quality@2-jev")
    #expect(report.arms[0].labelsVersion == "test-quality@1")
    let all = try #require(report.metrics.views.first { $0.labels == .all })
    guard case .measured(let arms, _) = all.outcome else {
      Issue.record("no numbers")
      return
    }
    #expect(arms[0].questions.map(\.question) == ["fails-if-broken", "asserts-implementation"])
    #expect(arms[0].questions[0].accuracy.n == 4)
  }

  static let cascadeArm = "cascade:jev-1.13.0,claude-sonnet-5-5"

  @Test(
    "a cascade arm asks Jev @2-jev and Claude only the escalated questions, scores the merged answers on @1 labels, records each case's escalations, and sums both backends' cost per case — catches cost counted on 1 backend"
  )
  func cascadeArmSumsBothBackends() async throws {
    let arm = try #require(try? JudgeBenchmarkArm.parse(Self.cascadeArm))
    #expect(arm.description == Self.cascadeArm)
    let jev = ServingJudge("jev", "jev-1.13.0", flagged: 0.5) { _ in "jev-1.13.0" }
    let claude = ServingJudge("claude", "claude-sonnet-5-5", flagged: 0.1) { _ in
      "claude-sonnet-5-5"
    }
    let cascade = CascadingJudge(
      jev: jev, claude: claude, base: .tests,
      policy: CascadingJudge.Policy(
        thresholds: JudgeThresholds(advisory: 0.5, block: 0.5), atReadyTier: true))

    let report = try await JudgeBench.run(
      try Self.plan(arms: [Self.cascadeArm]), judges: [cascade], startedAt: Date()
    ).get()

    #expect(jev.count == 12)
    #expect(claude.count == 12)
    let result = try #require(report.arms.first)
    #expect(
      result.identity
        == JudgeBenchmarkIdentity(
          backend: "cascade", requestedModel: "jev-1.13.0,claude-sonnet-5-5",
          servedModel: "jev-1.13.0"))
    #expect(result.questionSet == "test-quality@2-jev")
    #expect(result.labelsVersion == "test-quality@1")
    for answered in result.repeats {
      for replies in answered.values {
        #expect(replies.count == 2)
        #expect(
          replies.first?.escalations == [
            "fails-if-broken": .uncertain, "asserts-implementation": .uncertain,
          ])
        #expect(replies.last?.escalations == nil)
      }
    }
    let all = try #require(report.metrics.views.first { $0.labels == .all })
    guard case .measured(let arms, _) = all.outcome else {
      Issue.record("no numbers")
      return
    }
    #expect(arms[0].usage.costPerCase.value.map { abs($0 - 0.02) < 1e-12 } == true)
    // Jev's 0.5 would flag every case; Claude's 0.1 flags none, so these are Claude's answers.
    #expect(arms[0].questions[0].truePositiveRate.value == 0)
    #expect(arms[0].questions[0].trueNegativeRate.value == 1)
    let page = try JudgeBench.render(report.json).get()
    #expect(page.contains("### Escalations to Claude"))
    #expect(page.contains("| fails-if-broken | 1.00 (n=12: 12/12)"))

    let live = JudgeBench.liveJudge(
      arm, runner: Self.noProcess, environment: [:], questions: .testsJev)
    #expect(
      (live as? CascadingJudge)?.identity == JudgeIdentity(backend: "jev", model: "jev-1.13.0"))
  }

  @Test(
    "a cascade arm with an unknown set after #, 1 model, or an alias exits 2 naming it, and needs the Jev host — catches a malformed cascade benchmarked as something else"
  )
  func badCascadeArmsExitTwo() throws {
    let root = try Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "four.json")
    try JSONSerialization.data(withJSONObject: Self.datasetObject()).write(to: file)
    func refusal(_ arm: String, sendTo: String? = "api.typesafe.ai") -> JudgeBench.Refusal? {
      Self.refusal(
        JudgeBench.plan(
          Self.options(file.path, arms: [arm]) { $0.sendTo = sendTo }, root: root,
          harnessRoot: nil, configNamesHost: false, environment: [:]))
    }

    let unknownSet = refusal(Self.cascadeArm + "#test-quality@7")
    #expect(unknownSet?.status == 2)
    #expect(unknownSet?.message.contains("unknown question set `test-quality@7`") == true)
    let oneModel = refusal("cascade:jev-1.13.0")
    #expect(oneModel?.status == 2)
    #expect(oneModel?.message.contains("cascade:<jev model>,<claude model>") == true)
    let alias = refusal("cascade:jev-1.13.0,sonnet")
    #expect(alias?.message.contains("`sonnet` is an alias") == true)
    #expect(refusal(Self.cascadeArm, sendTo: nil)?.message.contains("--send-to") == true)
    #expect(refusal(Self.cascadeArm) == nil)
  }

  @Test(
    "--repeats 2 exits 2 unless --smoke over named cases — catches stability measured on 2 repeats"
  )
  func tooFewRepeatsExitTwo() throws {
    let root = try Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "four.json")
    try JSONSerialization.data(withJSONObject: Self.datasetObject()).write(to: file)

    let two = JudgeBench.plan(
      Self.options(file.path, repeats: 2), root: root, harnessRoot: nil, configNamesHost: false,
      environment: [:])
    let refusal = try #require(Self.refusal(two))
    #expect(refusal.status == 2)
    #expect(refusal.message.contains("--repeats 2"))

    let smokeWithoutCases = JudgeBench.plan(
      Self.options(file.path, repeats: 1) { $0.smoke = true }, root: root, harnessRoot: nil,
      configNamesHost: false, environment: [:])
    #expect(Self.refusal(smokeWithoutCases)?.status == 2)

    let smoke = try JudgeBench.plan(
      Self.options(file.path, repeats: 1) {
        $0.smoke = true
        $0.cases = ["case-0", "case-1"]
      }, root: root, harnessRoot: nil, configNamesHost: false, environment: [:]
    ).get()
    #expect(smoke.purpose == .smoke)
    #expect(smoke.cases.map(\.id) == ["case-0", "case-1"])
    #expect(smoke.judgments == [2, 2])

    let unknownCase = JudgeBench.plan(
      Self.options(file.path) { $0.cases = ["case-9"] }, root: root, harnessRoot: nil,
      configNamesHost: false, environment: [:])
    #expect(Self.refusal(unknownCase)?.message.contains("case-9") == true)

    let three = try JudgeBench.plan(
      Self.options(file.path), root: root, harnessRoot: nil, configNamesHost: false,
      environment: [:]
    ).get()
    #expect(three.purpose == .benchmark)
    #expect(three.cases.count == 4)
  }

  @Test(
    "a Jev arm needs the named host, and --send-to with no remote arm is refused — catches code sent to a host no one named"
  )
  func jevArmNeedsTheHost() throws {
    let root = try Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "four.json")
    try JSONSerialization.data(withJSONObject: Self.datasetObject()).write(to: file)
    let jev = ["jev:jev-1.13.0"]

    let unnamed = JudgeBench.plan(
      Self.options(file.path, arms: jev), root: root, harnessRoot: nil, configNamesHost: false,
      environment: [:])
    let refusal = try #require(Self.refusal(unnamed))
    #expect(refusal.status == 2)
    #expect(refusal.message.contains("--send-to api.typesafe.ai"))

    let wrongHost = JudgeBench.plan(
      Self.options(file.path, arms: jev) { $0.sendTo = "example.com" }, root: root,
      harnessRoot: nil, configNamesHost: false, environment: [:])
    #expect(Self.refusal(wrongHost)?.status == 2)

    let named = JudgeBench.plan(
      Self.options(file.path, arms: jev) { $0.sendTo = "api.typesafe.ai" }, root: root,
      harnessRoot: nil, configNamesHost: false, environment: [:])
    #expect(Self.refusal(named) == nil)
    let byConfig = JudgeBench.plan(
      Self.options(file.path, arms: jev), root: root, harnessRoot: nil, configNamesHost: true,
      environment: [:])
    #expect(Self.refusal(byConfig) == nil)

    let unused = JudgeBench.plan(
      Self.options(file.path) { $0.sendTo = "api.typesafe.ai" }, root: root, harnessRoot: nil,
      configNamesHost: false, environment: [:])
    #expect(Self.refusal(unused)?.status == 2)

    let plan = try named.get()
    #expect(JudgeBench.missingKey(plan, environment: [:])?.status == 2)
    #expect(JudgeBench.missingKey(plan, environment: ["TYPESAFE_API_KEY": "k"]) == nil)
  }

  @Test(
    "an unknown set version after # exits 2 naming it, and a dataset that can't load exits 2 — catches a typo benchmarked as the default set"
  )
  func badArmsAndDatasetsExitTwo() throws {
    let root = try Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "four.json")
    try JSONSerialization.data(withJSONObject: Self.datasetObject()).write(to: file)

    let unknownSet = JudgeBench.plan(
      Self.options(file.path, arms: ["jev:jev-1.13.0#test-quality@7"]) {
        $0.sendTo = "api.typesafe.ai"
      }, root: root, harnessRoot: nil, configNamesHost: false, environment: [:])
    let refusal = try #require(Self.refusal(unknownSet))
    #expect(refusal.status == 2)
    #expect(refusal.message.contains("test-quality@7"))

    let missing = JudgeBench.plan(
      Self.options(root.appending(path: "nope.json").path), root: root, harnessRoot: nil,
      configNamesHost: false, environment: [:])
    #expect(Self.refusal(missing)?.status == 2)

    let builtInWithoutRoot = JudgeBench.plan(
      Self.options("test-quality"), root: root, harnessRoot: nil, configNamesHost: false,
      environment: [:])
    #expect(Self.refusal(builtInWithoutRoot)?.message.contains("SWIFTGATE_HARNESS_ROOT") == true)

    let builtIn = try JudgeBench.dataset(
      "test-quality", root: root, harnessRoot: Fixture.checkoutRoot
    ).get()
    #expect(builtIn.id == "test-quality")
  }

  // MARK: - bench-render

  @Test(
    "bench-render renders an untouched result and exits 1 when 1 stored metric was edited — catches a hand-edited result"
  )
  func renderRefusesEditedMetrics() async throws {
    let claude = ServingJudge("claude", "claude-sonnet-5-5", flagged: 0.9)
    let jev = ServingJudge("jev", "jev-1.13.0", flagged: 0.2)
    let report = try await JudgeBench.run(
      try Self.plan(), judges: [claude, jev], startedAt: Date()
    ).get()
    let page = try JudgeBench.render(report.json).get()
    #expect(page.contains("## All labels"))
    #expect(page.contains("No person labels"))

    var object = try #require(
      try JSONSerialization.jsonObject(with: report.json) as? [String: Any])
    var metrics = try #require(object["metrics"] as? [String: Any])
    var views = try #require(metrics["views"] as? [[String: Any]])
    let index = try #require(views.firstIndex { $0["labels"] as? String == "all" })
    var outcome = try #require(views[index]["outcome"] as? [String: Any])
    var measured = try #require(outcome["measured"] as? [String: Any])
    var arms = try #require(measured["arms"] as? [[String: Any]])
    var questions = try #require(arms[0]["questions"] as? [[String: Any]])
    questions[0]["accuracy"] = ["count": 4, "n": 4]
    arms[0]["questions"] = questions
    measured["arms"] = arms
    outcome["measured"] = measured
    views[index]["outcome"] = outcome
    metrics["views"] = views
    object["metrics"] = metrics
    let refusal = try #require(
      Self.refusal(JudgeBench.render(try JSONSerialization.data(withJSONObject: object))))
    #expect(refusal.status == 1)
    #expect(refusal.message.contains("claude:claude-sonnet-5-5"))

    #expect(Self.refusal(JudgeBench.render(Data("{}".utf8)))?.status == 2)
  }

  @Test(
    "the built binary: judge bench --repeats 2 exits 2 and bench-render of an edited file exits 1 — catches exit codes lost between the command and the process"
  )
  func binaryExitCodes() async throws {
    let root = try Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try JSONSerialization.data(withJSONObject: Self.datasetObject()).write(
      to: root.appending(path: "four.json"))
    func swiftgate(_ arguments: [String]) async throws -> ProcessOutput {
      try await LiveProcessRunner().run(
        ProcessInvocation(
          executable: Fixture.gateDirectory.appending(path: ".build/debug/swiftgate").path,
          arguments: arguments,
          environmentOverlay: [
            "LLVM_PROFILE_FILE": root.appending(path: "swiftgate-%p.profraw").path
          ], workingDirectory: root.path, timeout: .seconds(120)))
    }
    let two = try await swiftgate([
      "judge", "bench", "--dataset", "four.json", "--backend", "claude:claude-sonnet-5-5",
      "--repeats", "2", "--out", "out.json",
    ])
    #expect(two.status == .exited(2))
    #expect(two.stderr.text.contains("--repeats 2"))
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "out.json").path))

    let estimate = try await swiftgate([
      "judge", "bench", "--dataset", "four.json", "--backend", "claude:claude-sonnet-5-5",
      "--estimate",
    ])
    #expect(estimate.status == .exited(0))
    #expect(estimate.stdout.text.contains("12 calls"))

    let report = try await JudgeBench.run(
      try Self.plan(), judges: [ServingJudge("claude", "c"), ServingJudge("jev", "j")],
      startedAt: Date()
    ).get()
    var object = try #require(
      try JSONSerialization.jsonObject(with: report.json) as? [String: Any])
    object["threshold"] = 0.9
    try JSONSerialization.data(withJSONObject: object).write(
      to: root.appending(path: "edited.json"))
    try report.json.write(to: root.appending(path: "good.json"))
    let edited = try await swiftgate(["judge", "bench-render", "edited.json"])
    #expect(edited.status == .exited(1))
    let good = try await swiftgate(["judge", "bench-render", "good.json", "--out", "page.md"])
    #expect(good.status == .exited(0))
    let page = try String(contentsOf: root.appending(path: "page.md"), encoding: .utf8)
    #expect(page.contains("# Judge benchmark: four"))
  }
}

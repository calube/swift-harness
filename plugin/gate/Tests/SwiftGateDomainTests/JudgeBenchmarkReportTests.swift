import Foundation
import Testing

@testable import SwiftGateDomain

@Suite(
  "judge bench result: arms, the versioned JSON, recomputed metrics, the page and the estimate")
struct JudgeBenchmarkReportTests {
  /// Ids whose SHA-256 starts at or above 0x55, so every one is in the report split.
  static let reportIDs = [0, 1, 4, 5].map { "case-\($0)" }
  static let failsIfBroken = JudgeQuestionSet.tests.questions[0]
  static let assertsImplementation = JudgeQuestionSet.tests.questions[3]
  static let labelled = [failsIfBroken, assertsImplementation]

  /// Case `i` is labelled positive on both questions when `i` is even.
  static func cases(labeller: JudgeDatasetLabeller = .agent) -> [JudgeBenchmarkLabelledCase] {
    reportIDs.enumerated().map { index, id in
      JudgeBenchmarkLabelledCase(
        id: id, labeller: labeller, declaredTier: "T1",
        expected: [
          failsIfBroken.id: index.isMultiple(of: 2) ? "no" : "yes",
          assertsImplementation.id: index.isMultiple(of: 2) ? "yes" : "no",
        ])
    }
  }

  /// 1 request per case per repeat; `p(repeat, caseIndex)` is the flagged probability of both
  /// questions.
  static func arm(
    _ name: String, repeats: Int = 3, cost: Double? = nil, p: (Int, Int) -> Double
  ) -> JudgeBenchmarkArmResult {
    let backend = String(name.prefix { $0 != ":" })
    let model = String(name.drop { $0 != ":" }.dropFirst())
    return JudgeBenchmarkArmResult(
      arm: name,
      identity: JudgeBenchmarkIdentity(backend: backend, requestedModel: model, servedModel: model),
      questionSet: "test-quality@1", labelsVersion: "test-quality@1",
      repeats: (0..<repeats).map { index in
        Dictionary(
          uniqueKeysWithValues: reportIDs.enumerated().map { caseIndex, id in
            let flagged = p(index, caseIndex)
            return (
              id,
              [
                JudgeBenchmarkReply(
                  JudgeReply(
                    answers: [
                      JudgeAnswer(
                        question: failsIfBroken.id,
                        distribution: ["no": flagged, "yes": 1 - flagged], rationale: nil),
                      JudgeAnswer(
                        question: assertsImplementation.id,
                        distribution: ["yes": flagged, "no": 1 - flagged], rationale: nil),
                    ],
                    usage: JudgeUsage(
                      inputTokens: 1000, outputTokens: 50, costUSD: cost,
                      wallMilliseconds: 1200 + caseIndex, servedModel: model)))
              ]
            )
          })
      })
  }

  static let summary = JudgeDatasetSummary(
    id: "test-quality", questionSet: "test-quality@1", hash: "abc", cases: 4, unlabelled: 0,
    splits: JudgeDatasetSplitCounts(tune: 0, report: 4),
    labellers: JudgeDatasetLabellerMix(person: 0, agent: 4, seed: 0))

  static func report(
    labeller: JudgeDatasetLabeller = .agent, arms: [JudgeBenchmarkArmResult]? = nil
  ) -> JudgeBenchmarkReport {
    JudgeBenchmarkReport(
      swiftgateVersion: "0.1.0", startedAt: "2026-09-30T20:00:00Z", purpose: .benchmark,
      dataset: summary, questions: labelled, cases: cases(labeller: labeller), threshold: 0.5,
      repeats: 3,
      arms: arms ?? [
        // Right on every case, with a wobble on case 1.
        arm("claude:claude-sonnet-5-5", cost: 0.02) { repeatIndex, caseIndex in
          caseIndex.isMultiple(of: 2) ? 0.9 : (repeatIndex == 1 && caseIndex == 1 ? 0.6 : 0.1)
        },
        // Wrong on case 2 only.
        arm("jev:jev-1.13.0") { _, caseIndex in
          caseIndex == 2 ? 0.3 : (caseIndex.isMultiple(of: 2) ? 0.8 : 0.2)
        },
      ])
  }

  static func object(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  // MARK: - Arms

  @Test(
    "an arm reads backend, pinned model and an optional built-in set after # — catches the set version dropped from the arm"
  )
  func parsesArms() throws {
    let claude = try JudgeBenchmarkArm.parse("claude:claude-sonnet-5-5")
    #expect(claude == JudgeBenchmarkArm(backend: .claude, model: "claude-sonnet-5-5"))
    #expect(claude.description == "claude:claude-sonnet-5-5")
    let native = try JudgeBenchmarkArm.parse("jev:jev-1.13.0#test-quality@2-jev")
    #expect(native.backend == .jev)
    #expect(native.model == "jev-1.13.0")
    #expect(native.questionSet == "test-quality@2-jev")
    #expect(native.description == "jev:jev-1.13.0#test-quality@2-jev")
  }

  @Test(
    "an alias, an unknown backend, a malformed arm and an unknown set version are refused by name — catches a benchmark of a moving model"
  )
  func refusesArms() {
    #expect(throws: JudgeBenchmarkArmError.notPinned(arm: "claude:sonnet", model: "sonnet")) {
      try JudgeBenchmarkArm.parse("claude:sonnet")
    }
    #expect(throws: JudgeBenchmarkArmError.notPinned(arm: "jev:jev-latest", model: "jev-latest")) {
      try JudgeBenchmarkArm.parse("jev:jev-latest")
    }
    #expect(
      throws: JudgeBenchmarkArmError.unknownBackend(arm: "gemini:gemini-3", backend: "gemini")
    ) {
      try JudgeBenchmarkArm.parse("gemini:gemini-3")
    }
    let oneModel = #expect(throws: JudgeBenchmarkArmError.self) {
      try JudgeBenchmarkArm.parse("cascade:jev-1.13.0")
    }
    #expect(oneModel.map { "\($0)" }?.contains("cascade:<jev model>,<claude model>") == true)
    #expect(throws: JudgeBenchmarkArmError.malformed("claude")) {
      try JudgeBenchmarkArm.parse("claude")
    }
    #expect(
      throws: JudgeBenchmarkArmError.unknownQuestionSet(
        arm: "jev:jev-1.13.0#test-quality@9", questionSet: "test-quality@9",
        known: ["test-quality@1", "test-quality@2-jev", "comments@1"])
    ) {
      try JudgeBenchmarkArm.parse("jev:jev-1.13.0#test-quality@9")
    }
    let message = "\(JudgeBenchmarkArmError.notPinned(arm: "claude:sonnet", model: "sonnet"))"
    #expect(message.contains("sonnet"))
  }

  static func dataset(_ set: JudgeQuestionSet = .tests) throws -> JudgeDataset {
    try JudgeDataset(
      id: "test-quality", questionSet: .builtIn(set),
      cases: [
        JudgeDatasetCase(
          id: "case-0", source: "func test() {}", context: "diff", declaredTier: "T1",
          labels: [
            set.versionedID: JudgeDatasetLabel(labeller: .agent, expected: [failsIfBroken.id: "no"])
          ])
      ])
  }

  @Test(
    "Jev on test-quality@2-jev asks the rendered set and reads @1's labels — catches the native set scored against no labels"
  )
  func nativeSetReadsBaseLabels() throws {
    let dataset = try Self.dataset()
    let native = try JudgeBenchmarkArm.parse("jev:jev-1.13.0#test-quality@2-jev")
    let asked = try native.questions(for: dataset)
    #expect(asked == .testsJev)
    #expect(asked.labelsVersion == dataset.labelsVersion)
    let plain = try JudgeBenchmarkArm.parse("claude:claude-sonnet-5-5").questions(for: dataset)
    #expect(plain == .tests)

    let cut = JudgeBenchmarkArm.questions(
      .testsJev, for: dataset.cases[0], labelsVersion: dataset.labelsVersion)
    #expect(cut.questions.map(\.id) == [Self.failsIfBroken.id])
    #expect(cut.rendering == .jev)
    #expect(cut.basedOn == "test-quality@1")
  }

  @Test(
    "a rendered set asked of another backend, or a set with other labels, is refused — catches Claude asked Jev's rendering"
  )
  func refusesMismatchedSets() throws {
    let dataset = try Self.dataset()
    #expect(
      throws: JudgeBenchmarkArmError.renderedForOtherBackend(
        arm: "claude:claude-sonnet-5-5#test-quality@2-jev", questionSet: "test-quality@2-jev",
        rendering: "jev")
    ) {
      try JudgeBenchmarkArm.parse("claude:claude-sonnet-5-5#test-quality@2-jev").questions(
        for: dataset)
    }
    #expect(
      throws: JudgeBenchmarkArmError.otherLabels(
        arm: "claude:claude-sonnet-5-5#comments@1", questionSet: "comments@1",
        labels: "comments@1", dataset: "test-quality@1")
    ) {
      try JudgeBenchmarkArm.parse("claude:claude-sonnet-5-5#comments@1").questions(for: dataset)
    }
  }

  // MARK: - The JSON

  @Test(
    "the JSON holds 3 repeats × 4 cases × 2 arms of raw answers, the labeller of each case, and round-trips — catches answers kept only as metrics"
  )
  func jsonHoldsRawAnswers() throws {
    let report = Self.report()
    let object = try Self.object(report.json)
    #expect(object["schemaVersion"] as? Int == 1)
    #expect(object["swiftgateVersion"] as? String == "0.1.0")
    let arms = try #require(object["arms"] as? [[String: Any]])
    #expect(arms.count == 2)
    var replies = 0
    for arm in arms {
      let repeats = try #require(arm["repeats"] as? [[String: [Any]]])
      #expect(repeats.count == 3)
      for answered in repeats {
        #expect(answered.keys.sorted() == Self.reportIDs.sorted())
        replies += answered.values.map(\.count).reduce(0, +)
      }
      let identity = try #require(arm["identity"] as? [String: Any])
      #expect(identity["requestedModel"] != nil)
      #expect(identity["servedModel"] != nil)
    }
    #expect(replies == 3 * 4 * 2)
    let cases = try #require(object["cases"] as? [[String: Any]])
    #expect(cases.map { $0["labeller"] as? String } == Array(repeating: "agent", count: 4))
    let dataset = try #require(object["dataset"] as? [String: Any])
    #expect(dataset["hash"] as? String == "abc")

    #expect(try JudgeBenchmarkReport.decode(report.json) == report)
  }

  @Test(
    "an unknown key at the top or deep inside is rejected naming its path — catches a misspelt field read as absent"
  )
  func rejectsUnknownKeys() throws {
    var top = try Self.object(Self.report().json)
    top["note"] = "hand-added"
    #expect(throws: JudgeBenchmarkReportError.malformed("unknown key `note`")) {
      try JudgeBenchmarkReport.decode(try JSONSerialization.data(withJSONObject: top))
    }

    var deep = try Self.object(Self.report().json)
    var arms = try #require(deep["arms"] as? [[String: Any]])
    var identity = try #require(arms[0]["identity"] as? [String: Any])
    identity["servedModle"] = "x"
    arms[0]["identity"] = identity
    deep["arms"] = arms
    #expect(
      throws: JudgeBenchmarkReportError.malformed("unknown key `arms[0].identity.servedModle`")
    ) {
      try JudgeBenchmarkReport.decode(try JSONSerialization.data(withJSONObject: deep))
    }

    var future = try Self.object(Self.report().json)
    future["schemaVersion"] = 2
    #expect(throws: JudgeBenchmarkReportError.unsupportedSchema(2)) {
      try JudgeBenchmarkReport.decode(try JSONSerialization.data(withJSONObject: future))
    }
  }

  @Test(
    "the stored metrics equal JudgeBenchmarkMetrics over the raw answers — catches metrics computed by a second copy"
  )
  func metricsComeFromTheMetricsType() throws {
    let report = Self.report()
    let all = try #require(report.metrics.views.first { $0.labels == .all })
    guard case .measured(let arms, let pairs) = all.outcome else {
      Issue.record("the all-labels view has no numbers")
      return
    }
    let runs = report.arms.map(\.run)
    let cases = JudgeReportCases(report.cases.map(\.benchmarkCase))
    #expect(
      arms[0].questions[0]
        == JudgeBenchmarkMetrics.question(
          Self.failsIfBroken, cases: cases, run: runs[0], threshold: 0.5))
    #expect(arms[1].usage == JudgeBenchmarkMetrics.usage(cases: cases, run: runs[1]))
    #expect(
      pairs[0].questions[1]
        == JudgeBenchmarkMetrics.compare(
          Self.assertsImplementation, cases: cases, runs[0], runs[1], threshold: 0.5))
    #expect(runs[0].identity == JudgeIdentity(backend: "claude", model: "claude-sonnet-5-5"))
    #expect(runs[0].repeats.count == 3)
    // Jev misses case 2, a positive: 1 of 2 positives found.
    #expect(arms[1].questions[0].truePositiveRate == JudgeProportion(count: 1, n: 2))
  }

  @Test(
    "verify passes an untouched result and names the place of 1 edited metric — catches a hand-edited result"
  )
  func verifyRefusesAnEditedMetric() throws {
    let report = Self.report()
    let decoded = try JudgeBenchmarkReport.decode(report.json)
    try decoded.verify()

    var object = try Self.object(report.json)
    let edited = try JSONSerialization.data(withJSONObject: object)
    #expect(try JudgeBenchmarkReport.decode(edited) == report)
    var metrics = try #require(object["metrics"] as? [String: Any])
    var views = try #require(metrics["views"] as? [[String: Any]])
    let allIndex = try #require(views.firstIndex { $0["labels"] as? String == "all" })
    var outcome = try #require(views[allIndex]["outcome"] as? [String: Any])
    var measured = try #require(outcome["measured"] as? [String: Any])
    var arms = try #require(measured["arms"] as? [[String: Any]])
    var questions = try #require(arms[1]["questions"] as? [[String: Any]])
    questions[0]["truePositiveRate"] = ["count": 2, "n": 2]
    arms[1]["questions"] = questions
    measured["arms"] = arms
    outcome["measured"] = measured
    views[allIndex]["outcome"] = outcome
    metrics["views"] = views
    object["metrics"] = metrics
    let tampered = try JudgeBenchmarkReport.decode(
      try JSONSerialization.data(withJSONObject: object))
    #expect(
      throws: JudgeBenchmarkReportError.metricsDiffer([
        "all labels, jev:jev-1.13.0, fails-if-broken"
      ])
    ) {
      try tampered.verify()
    }
  }

  // MARK: - Labels

  @Test(
    "with only agent and seed labels the person view says no person labels and shows no numbers — catches agent numbers under a person heading"
  )
  func personViewWithoutPersonLabels() throws {
    let report = Self.report(labeller: .agent)
    let person = try #require(report.metrics.views.first { $0.labels == .person })
    #expect(person.outcome == .noLabels)
    #expect(person.reportCases == 0)
    let page = report.markdown
    let personStart = try #require(page.range(of: "## Person labels"))
    let allStart = try #require(page.range(of: "## All labels"))
    let personSection = String(page[personStart.upperBound..<allStart.lowerBound])
    #expect(personSection.contains("No person labels"))
    #expect(!personSection.contains("Precision"))
    #expect(!personSection.contains("(n="))
    #expect(page[allStart.upperBound...].contains("Precision"))
  }

  @Test(
    "the person view scores only person-labelled cases — catches the person view reading every label"
  )
  func personViewReadsOnlyPersonLabels() throws {
    var cases = Self.cases(labeller: .agent)
    cases[0] = JudgeBenchmarkLabelledCase(
      id: cases[0].id, labeller: .person, declaredTier: "T1", expected: cases[0].expected)
    cases[1] = JudgeBenchmarkLabelledCase(
      id: cases[1].id, labeller: .person, declaredTier: "T1", expected: cases[1].expected)
    let base = Self.report()
    let metrics = JudgeBenchmarkReport.metrics(
      questions: Self.labelled, cases: cases, arms: base.arms, threshold: 0.5)
    let person = try #require(metrics.views.first { $0.labels == .person })
    let all = try #require(metrics.views.first { $0.labels == .all })
    #expect(person.reportCases == 2)
    #expect(all.reportCases == 4)
    guard case .measured(let arms, _) = person.outcome else {
      Issue.record("the person view has no numbers")
      return
    }
    #expect(arms[0].questions[0].accuracy.n == 2)
  }

  // MARK: - The page

  @Test(
    "every rate, estimate and latency on the page carries its n — catches a bare rate"
  )
  func everyNumberCarriesItsN() {
    let page = Self.report().markdown
    let rows = page.split(separator: "\n").filter {
      $0.hasPrefix("| Precision") || $0.hasPrefix("| True-positive rate")
        || $0.hasPrefix("| True-negative rate") || $0.hasPrefix("| Accuracy")
        || $0.hasPrefix("| Brier") || $0.hasPrefix("| Calibration error")
        || $0.hasPrefix("| Request latency") || $0.hasPrefix("| Cost per case")
    }
    #expect(rows.count >= 2 * 6 + 2)
    for row in rows {
      let cells = row.split(separator: "|").dropFirst().map {
        $0.trimmingCharacters(in: .whitespaces)
      }
      for cell in cells where !cell.isEmpty {
        #expect(cell.contains("(n="), "\(row)")
      }
    }
    #expect(page.contains("0.50 (n=2: 1/2)"))
    #expect(page.contains("claude-sonnet-5-5"))
    #expect(page.contains("abc"))
  }

  @Test(
    "a difference whose interval crosses 0 gets the sentence saying so, and every disagreement shows both probabilities — catches a tie read as a win"
  )
  func pageSaysWhenADifferenceCrossesZero() {
    let page = Self.report().markdown
    #expect(page.contains("crosses 0"))
    #expect(page.contains("| case-4 | 0.90 (flags) | 0.30 (passes) |"))
  }

  @Test(
    "a smoke run says it measures nothing, and 1 repeat shows too few repeats for stability — catches a smoke run read as a benchmark"
  )
  func smokeRunSaysSo() throws {
    let report = JudgeBenchmarkReport(
      swiftgateVersion: "0.1.0", startedAt: "2026-09-30T20:00:00Z", purpose: .smoke,
      dataset: Self.summary, questions: Self.labelled, cases: Self.cases(), threshold: 0.5,
      repeats: 1, arms: [Self.arm("claude:claude-sonnet-5-5", repeats: 1) { _, _ in 0.9 }])
    #expect(report.markdown.contains("Smoke run"))
    #expect(report.markdown.contains("too few repeats"))
    try JudgeBenchmarkReport.decode(report.json).verify()
  }

  // MARK: - The estimate

  @Test(
    "the estimate counts calls and prices each arm at its recorded mean cost per uncached call — catches spend estimated from nothing"
  )
  func estimatesFromRecordedUsage() throws {
    let claude = try JudgeBenchmarkArm.parse("claude:claude-sonnet-5-5")
    let jev = try JudgeBenchmarkArm.parse("jev:jev-1.13.0")
    let recorded = [
      JudgeBenchmarkEstimate.Recorded(
        backend: "claude", model: "claude-sonnet-5-5",
        usages: [
          JudgeUsage(costUSD: 0.25, wallMilliseconds: 1),
          JudgeUsage(costUSD: 0.75, wallMilliseconds: 1),
          JudgeUsage(costUSD: 0, wallMilliseconds: 1, cached: true),
        ], source: "smoke.json"),
      // Another model's price never stands in.
      JudgeBenchmarkEstimate.Recorded(
        backend: "claude", model: "claude-opus-5-5",
        usages: [JudgeUsage(costUSD: 1, wallMilliseconds: 1)], source: "other.json"),
    ]
    let estimate = JudgeBenchmarkEstimate.make(
      arms: [claude, jev], judgments: [4, 4, 3], repeats: 3, recorded: recorded)
    try #require(estimate.arms.count == 2)
    #expect(estimate.arms.map(\.calls) == [9, 9])
    #expect(estimate.arms.map(\.judgments) == [33, 33])
    // 9 calls at a mean of 0.5.
    let claudeCost = try #require(estimate.arms[0].costUSD)
    #expect(claudeCost == 4.5)
    #expect(
      estimate.arms[0].basis == .recorded(meanPerCall: 0.5, calls: 2, sources: ["smoke.json"]))
    #expect(estimate.arms[1].costUSD == nil)
    #expect(estimate.arms[1].basis == .noRecordedUsage)
    #expect(estimate.claudeCostUSD == 4.5)
    #expect(estimate.text.contains("no calls"))
    #expect(estimate.text.contains("--usage-from"))

    let unknown = JudgeBenchmarkEstimate.make(
      arms: [claude], judgments: [4], repeats: 3, recorded: [])
    #expect(unknown.claudeCostUSD == nil)
  }

  @Test(
    "recorded usage reads from a bench result and from a judge recording — catches an estimate that ignores the smoke run"
  )
  func readsRecordedUsage() throws {
    let fromBench = try JudgeBenchmarkEstimate.recorded(
      from: Self.report().json, source: "bench.json")
    try #require(fromBench.count == 2)
    #expect(fromBench.map(\.backend) == ["claude", "jev"])
    #expect(fromBench[0].model == "claude-sonnet-5-5")
    #expect(fromBench[0].usages.count == 12)
    #expect(fromBench[0].source == "bench.json")

    let recording = JudgeCalibrationRecording(
      questionSet: "test-quality@1",
      identity: JudgeIdentity(backend: "claude", model: "claude-sonnet-5-5"),
      servedModels: nil, answers: ["a": []],
      usage: ["a": JudgeUsage(costUSD: 0.05, wallMilliseconds: 10)])
    let fromRecording = try JudgeBenchmarkEstimate.recorded(
      from: try JSONEncoder().encode(recording), source: "recording.json")
    #expect(fromRecording.map(\.usages.count) == [1])

    #expect(throws: JudgeBenchmarkReportError.self) {
      try JudgeBenchmarkEstimate.recorded(from: Data("{}".utf8), source: "x.json")
    }
  }
}

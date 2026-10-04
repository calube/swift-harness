import Foundation
import SwiftGateDomain
import Testing

@Suite struct BrownfieldRunReportTests {
  private static let planText = """
    # Export the report as CSV

    ## Areas

    - api (warm test 12 s)
    - web (warm test 41 s, build-only)

    ## Assumptions

    - CSV only, since it is the 1 format the spec's example shows.
    - Column order follows the on-screen table,
      left to right.

    ### report-export-contract
    Declare the export types.
    - Deps: none · Gate: slice · estLines: 40
    - Writes: api/export.py
    """

  private static let baseline = BaselineFile(
    tree: "abc123",
    records: [
      BaselineRecord(
        key: BaselineStepKey(area: "api", step: .test, command: "pytest"),
        result: .failedTests(["tests.test_dates.test_leap_year"])),
      BaselineRecord(
        key: BaselineStepKey(area: "web", step: .build, command: "npm run build"),
        result: .passed),
    ])

  private static func discover(edits: [DiscoverEdit] = []) -> DiscoverRecord {
    let api = ProposedArea(
      name: "api", root: "api", language: .python, kind: .python, source: "api/pyproject.toml",
      commands: [
        .test: Sourced(value: "pytest", source: "api/pyproject.toml", confidence: .found)
      ],
      missing: [
        .lint: "the orchestrator dropped it: ruff isn't installed",
        .e2e: "none configured",
      ],
      testGlobs: ["api/tests/**/*.py"], xcode: nil, generatedProjectTracked: nil)
    return DiscoverRecord(
      proposal: DiscoverProposal(head: "abc", areas: [api], dirty: []), edits: edits)
  }

  private static func build(
    review: BuildPreset.Review = .classified, events: [BuildEvent],
    damage: [BuildEventLog.Damage] = []
  ) -> RunReportBuild {
    let base = Discover.brownfieldPreset
    let preset = BuildPreset(
      designTier: base.designTier, maxParallel: base.maxParallel, review: review,
      taskGate: base.taskGate, mergeGate: base.mergeGate, workerModel: base.workerModel,
      timeBudgetMin: base.timeBudgetMin, stopStartsBeforeMin: base.stopStartsBeforeMin,
      onDesignConflict: base.onDesignConflict, taskProof: base.taskProof, stallMin: base.stallMin)
    return RunReportBuild(
      record: BuildRunRecord(
        runID: "20261004T010000Z-a1", plan: "csv", startedAt: Date(timeIntervalSince1970: 0),
        presetName: "brownfield", preset: preset),
      log: BuildEventLog(events: events, damage: damage))
  }

  private static let at = Date(timeIntervalSince1970: 100)

  /// A ledger whose every task is done, as a run that built its whole plan leaves it.
  private static let finishedLedger = Ledger(
    schemaVersion: 1, resume: "done", maxParallel: 3,
    tasks: ["report-export-contract", "report-export-api"].map {
      LedgerTask(
        id: $0, deps: [], writeSet: ["api/"], gate: .slice, tests: [], covers: [], estLines: 40,
        status: .done, worktree: "/CLONE/.git/swift-harness/plans/csv/worktrees/\($0)")
    }, waves: [["report-export-contract"], ["report-export-api"]])

  private static func inputs(
    ledger: RunReportInput<Ledger> = .read(finishedLedger),
    planBranchHead: String? = "f00dbeef",
    plan: RunReportInput<String> = .read(planText),
    baseline: RunReportInput<BaselineFile> = .read(baseline),
    discover: RunReportInput<DiscoverRecord> = .read(discover()),
    build: RunReportInput<RunReportBuild> = .read(
      build(events: [
        .merge(.init(task: "report-export-api", preCommit: "a", postCommit: "b", at: at)),
        .gate(.init(stage: .final, tier: .final, verdict: .green, runID: "gate-1", at: at)),
      ]))
  ) -> BrownfieldRunReportInputs {
    BrownfieldRunReportInputs(
      slug: "csv", planBranch: "swift-harness/csv", planBranchHead: planBranchHead, plan: plan,
      baseline: baseline, discover: discover, build: build, ledger: ledger)
  }

  /// The bullets under `## <title>` in the report's text.
  private func lines(_ title: String, in text: String) -> [String] {
    var inside = false
    var found: [String] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      if line.hasPrefix("## ") {
        inside = line == "## \(title)"
        continue
      }
      if inside, line.hasPrefix("- ") { found.append(String(line.dropFirst(2))) }
    }
    return found
  }

  @Test(
    "the assumptions, a baseline failure and a build-only area each render in their section — catches a dropped section"
  )
  func sectionsRender() {
    let report = BrownfieldRunReport.make(Self.inputs())
    #expect(
      report.assumptions.items == [
        "CSV only, since it is the 1 format the spec's example shows.",
        "Column order follows the on-screen table, left to right.",
      ])
    #expect(
      report.baselineFailures.items == [
        .init(area: "api", step: .test, test: "tests.test_dates.test_leap_year")
      ])
    #expect(report.buildOnlyAreas.items == ["web (warm test 41 s, build-only)"])

    let text = report.text
    #expect(lines("Assumptions", in: text).count == 2)
    #expect(lines("Baseline failures", in: text) == ["api test: tests.test_dates.test_leap_year"])
    #expect(lines("Build-only areas", in: text) == ["web (warm test 41 s, build-only)"])
  }

  @Test(
    "a missing baseline file is a line saying so — catches an empty section read as no failures")
  func missingBaseline() throws {
    let path = "/clone/.git/swift-harness/baseline/abc123.json"
    let report = BrownfieldRunReport.make(Self.inputs(baseline: .missing(path: path)))
    #expect(report.baselineFailures.items.isEmpty)
    let note = try #require(report.baselineFailures.note)
    #expect(note.contains(path))
    let rendered = lines("Baseline failures", in: report.text)
    #expect(rendered.count == 1)
    #expect(rendered.first?.contains(path) == true)
    #expect(rendered.first != "none")
  }

  @Test("a section whose source read fine and holds nothing says none — catches an empty heading")
  func emptySectionSaysNone() {
    let clean = BaselineFile(
      tree: "abc123",
      records: [
        BaselineRecord(
          key: BaselineStepKey(area: "api", step: .test, command: "pytest"), result: .passed)
      ])
    let report = BrownfieldRunReport.make(Self.inputs(baseline: .read(clean)))
    #expect(report.baselineFailures == .init(items: [], note: nil))
    #expect(lines("Baseline failures", in: report.text) == ["none"])
  }

  @Test(
    "a dropped step carries its reason and a never-configured e2e stays out — catches a silent drop"
  )
  func droppedSteps() {
    let edit = DiscoverEdit(
      area: "api", step: .lint, change: .drop(reason: "ruff isn't installed"))
    let report = BrownfieldRunReport.make(
      Self.inputs(discover: .read(Self.discover(edits: [edit]))))
    #expect(
      report.droppedSteps.items == [.init(area: "api", step: .lint, reason: "ruff isn't installed")]
    )
    #expect(lines("Dropped steps", in: report.text) == ["api lint: ruff isn't installed"])
  }

  @Test("the final verdict leads the report, the last final gate winning — catches a stale verdict")
  func finalVerdictFirst() {
    let report = BrownfieldRunReport.make(
      Self.inputs(
        build: .read(
          Self.build(events: [
            .gate(.init(stage: .final, tier: .final, verdict: .red, runID: "gate-1", at: Self.at)),
            .gate(
              .init(
                stage: .merge(task: "t"), tier: .merge, verdict: .green, runID: "gate-2",
                at: Self.at)),
            .gate(
              .init(stage: .final, tier: .final, verdict: .green, runID: "gate-3", at: Self.at)),
          ]))))
    #expect(report.final == .init(verdict: .green, runID: "gate-3"))
    let first = report.text.split(separator: "\n").first.map(String.init)
    #expect(first?.contains("GREEN") == true)
    #expect(first?.contains("gate-3") == true)
  }

  @Test("a run with no final gate says so on the first line — catches a report read as GREEN")
  func noFinalGate() {
    let report = BrownfieldRunReport.make(Self.inputs(build: .read(Self.build(events: []))))
    #expect(report.final == nil)
    #expect(report.finalNote != nil)
    let first = report.text.split(separator: "\n").first.map(String.init) ?? ""
    #expect(!first.contains("GREEN"))
    #expect(first.contains("no final gate"))
  }

  @Test("classified review names the tasks it reviewed at medium — catches a silent review depth")
  func reviewFallback() {
    let report = BrownfieldRunReport.make(Self.inputs())
    #expect(report.reviewFallbacks.items.count == 1)
    #expect(report.reviewFallbacks.items.first?.contains("report-export-api") == true)
    #expect(report.reviewFallbacks.items.first?.contains("medium") == true)

    let full = BrownfieldRunReport.make(
      Self.inputs(build: .read(Self.build(review: .full, events: []))))
    #expect(full.reviewFallbacks == .init(items: [], note: nil))
  }

  @Test("the plan branch to merge is named with its head, or as missing — catches a dangling name")
  func planBranch() {
    let present = BrownfieldRunReport.make(Self.inputs()).text
    #expect(
      lines("Plan branch", in: present).contains {
        $0.contains("swift-harness/csv") && $0.contains("f00dbeef")
      })

    let absent = BrownfieldRunReport.make(Self.inputs(planBranchHead: nil)).text
    let line = lines("Plan branch", in: absent).first ?? ""
    #expect(line.contains("swift-harness/csv"))
    #expect(line.contains("doesn't exist"))
  }

  @Test("an unreadable PLAN.md is a line in both plan sections — catches an empty assumptions list")
  func unreadablePlan() {
    let report = BrownfieldRunReport.make(
      Self.inputs(plan: .missing(path: "/clone/.git/swift-harness/plans/csv/PLAN.md")))
    #expect(report.assumptions.note?.contains("PLAN.md") == true)
    #expect(report.buildOnlyAreas.note?.contains("PLAN.md") == true)
    #expect(lines("Assumptions", in: report.text).first?.contains("PLAN.md") == true)
  }

  @Test("the JSON keeps every section's items and note — catches a key the text has and JSON lacks")
  func jsonShape() throws {
    let report = BrownfieldRunReport.make(Self.inputs(baseline: .missing(path: "/b.json")))
    let data = try JSONEncoder().encode(report)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let baseline = try #require(object["baselineFailures"] as? [String: Any])
    #expect((baseline["note"] as? String)?.contains("/b.json") == true)
    let final = try #require(object["final"] as? [String: Any])
    #expect(final["verdict"] as? String == "GREEN")
  }
}

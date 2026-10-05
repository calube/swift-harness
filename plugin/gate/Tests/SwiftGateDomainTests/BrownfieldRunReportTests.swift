import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
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
      ])),
    validation: RunReportInput<QAReport>? = nil,
    setAside: RunReportInput<CommittedConfigSetAside>? = nil
  ) -> BrownfieldRunReportInputs {
    BrownfieldRunReportInputs(
      slug: "csv", planBranch: "swift-harness/csv", planBranchHead: planBranchHead, plan: plan,
      baseline: baseline, discover: discover, build: build, ledger: ledger,
      validation: validation, setAside: setAside)
  }

  @Test(
    "a run that set the committed config aside says so in its own section, and a record that won't read says why — catches a run on the brownfield profile reported as if the repository's own config governed it"
  )
  func committedConfigSection() {
    let record = CommittedConfigSetAside(
      blob: "4b825dc642cb6eb9a060e54bf8d69288fbee4904",
      setAsideAt: Date(timeIntervalSince1970: 1_800_000_000))
    let path = "/clone/.git/swift-harness/committed-config-set-aside.json"

    let read = BrownfieldRunReport.make(Self.inputs(setAside: .read(record)))
    let broken = BrownfieldRunReport.make(
      Self.inputs(setAside: .unreadable(source: path, reason: "not JSON")))
    let none = BrownfieldRunReport.make(Self.inputs(setAside: .missing(path: path)))

    #expect(read.committedConfig == .init(items: [record.reportLine], note: nil))
    #expect(
      lines("Committed config", in: read.text) == [
        ".swiftgate.toml (blob 4b825dc642cb6eb9a060e54bf8d69288fbee4904) set aside for this "
          + "clone at 2027-01-15T08:00:00Z: every command ran the brownfield profile, and the "
          + "file is unchanged in the tree"
      ])
    #expect(broken.committedConfig?.note?.contains(path) == true)
    #expect(none.committedConfig == nil)
    #expect(!none.text.contains("## Committed config"))
  }

  @Test(
    "a final GREEN over a qa run that verified no row says so straight after the final line — catches a run report that leads with GREEN when no validation row ran"
  )
  func validationLineNamesUnverifiedRows() throws {
    let captured = try QAReportJSON.decode(
      try Fixture.data("QA/aidoku-validation/final-report.json"))

    let report = BrownfieldRunReport.make(Self.inputs(validation: .read(captured)))

    #expect(
      report.validation
        == .init(runID: "20261004T213430Z-5250c2ac", verdict: .green, rows: 3, verified: 0))
    let head = report.text.split(separator: "\n", omittingEmptySubsequences: false).prefix(2)
    #expect(
      Array(head) == [
        "final: GREEN (gate run gate-1)",
        "validation: 0 of 3 rows verified (qa run 20261004T213430Z-5250c2ac, GREEN)",
      ])
  }

  @Test(
    "a plan with a validation table and no whole qa run says validation wasn't recorded, and a plan with no table has no validation line — catches a missing qa run read as nothing to verify"
  )
  func validationNotRecorded() {
    let missing = BrownfieldRunReport.make(
      Self.inputs(validation: .missing(path: "/clone/.harness/runs")))
    let none = BrownfieldRunReport.make(Self.inputs())

    #expect(missing.validation == nil)
    #expect(missing.validationNote?.contains("/clone/.harness/runs") == true)
    #expect(
      missing.text.split(separator: "\n").dropFirst().first?
        .hasPrefix("validation: not recorded; ") == true, "\(missing.text)")
    #expect(none.validationNote == nil)
    #expect(!none.text.contains("validation:"))
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

  @Test(
    "a step the baseline found not installed is a dropped step, not a baseline failure — catches a missing linter listed as the base tree failing"
  )
  func notInstalledIsDroppedNotBaseline() {
    let lint = BaselineStepKey(
      area: "web", step: .lint, command: "eslint {files}", selection: ["web/export.ts"])
    let file = BaselineFile(
      tree: "abc123", records: Self.baseline.records + [.init(key: lint, result: .notInstalled)])
    let report = BrownfieldRunReport.make(
      Self.inputs(baseline: .read(file), discover: .read(Self.discover())))

    #expect(
      report.baselineFailures.items == [
        .init(area: "api", step: .test, test: "tests.test_dates.test_leap_year")
      ])
    #expect(!lines("Baseline failures", in: report.text).contains { $0.contains("lint") })
    let dropped = lines("Dropped steps", in: report.text)
    #expect(dropped.contains { $0.hasPrefix("web lint: ") && $0.contains("isn't installed") })
    #expect(report.droppedSteps.items.filter { $0.area == "web" && $0.step == .lint }.count == 1)
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

  @Test(
    "a test 2 baseline records both fail, under 2 commands for 1 step, is 1 line — catches a duplicated baseline line"
  )
  func baselineLinesDedupe() {
    let test = "github.com/usememos/memos/scripts.TestEntrypointDoesNotLoopWhenTargetUIDIsRoot"
    let file = BaselineFile(
      tree: "abc123",
      records: [
        BaselineRecord(
          key: BaselineStepKey(area: "memos", step: .test, command: "go test -json ./..."),
          result: .failedTests([test])),
        BaselineRecord(
          key: BaselineStepKey(
            area: "memos", step: .test, command: "DRIVER=sqlite go test -json ./..."),
          result: .failedTests([test, "store.TestMemoShare"])),
        BaselineRecord(
          key: BaselineStepKey(area: "web", step: .test, command: "pnpm test"), result: .failed),
      ])
    let report = BrownfieldRunReport.make(Self.inputs(baseline: .read(file)))
    #expect(
      report.baselineFailures.items
        == [
          .init(area: "memos", step: .test, test: test),
          .init(area: "memos", step: .test, test: "store.TestMemoShare"),
          .init(area: "web", step: .test, test: nil),
        ].sorted { ($0.area, $0.test ?? "") < ($1.area, $1.test ?? "") })
    #expect(lines("Baseline failures", in: report.text).filter { $0.hasSuffix(test) }.count == 1)
  }

  /// A return the fourth `usememos/memos` trial's `build-task` workflow handed back.
  private static func memos4Return(_ task: String) throws -> TaskReturn {
    try TaskReturnJSON.decode(Fixture.data("BuildReturn/memos-4/\(task).json"))
  }

  /// `taskReturn` with `notes` in place of its own.
  private static func noting(_ notes: String, _ taskReturn: TaskReturn, task: String)
    -> TaskReturn
  {
    TaskReturn(
      task: task, outcome: taskReturn.outcome, commits: taskReturn.commits,
      gate: taskReturn.gate, review: taskReturn.review, testsAdded: taskReturn.testsAdded,
      notes: notes, designConflict: taskReturn.designConflict,
      surfaceCommit: taskReturn.surfaceCommit)
  }

  private static func started(_ task: String) -> BuildEvent {
    .transition(.init(task: task, from: .pending, to: .inProgress, at: at))
  }

  @Test(
    "classified review's fallbacks give each reviewed task's depth and why from its return, and leave out a task diff-risk rated, a design conflict and a task landed with no review — catches none, or a stale reason, when reviews fell back"
  )
  func reviewFallbacksPerTask() throws {
    let web = try Self.memos4Return("share-view-limit-web")
    let store = try Self.memos4Return("share-view-limit-store")
    let rated = Self.noting(
      "Both tests pass.\nreview: classified at low by swiftgate judge diff-risk", web, task: "docs")
    var build = Self.build(events: [
      Self.started("contract"),
      .transition(.init(task: "contract", from: .inProgress, to: .done, at: Self.at)),
      Self.started("share-view-limit-store"), Self.started("share-view-limit-web"),
      Self.started("api"), Self.started("docs"),
      .transition(
        .init(task: "share-view-limit-web", from: .inProgress, to: .blocked, at: Self.at)),
      .merge(.init(task: "api", preCommit: "a", postCommit: "b", at: Self.at)),
      .merge(.init(task: "docs", preCommit: "b", postCommit: "c", at: Self.at)),
      .transition(
        .init(task: "share-view-limit-store", from: .inProgress, to: .blocked, at: Self.at)),
    ])
    build = RunReportBuild(
      record: build.record, log: build.log,
      returns: [
        "share-view-limit-web": .read(web), "share-view-limit-store": .read(store),
        "docs": .read(rated),
      ])

    let report = BrownfieldRunReport.make(Self.inputs(build: .read(build)))

    #expect(
      report.reviewFallbacks.items == [
        "share-view-limit-web (blocked): classified review ran at medium, because diff-risk gave "
          + "no level: the clone's config has no [judge] section",
        "api (merged): review depth unknown: the build run stored no checked return for it",
      ])
    #expect(report.reviewFallbacks.note == nil)
    #expect(lines("Review fallbacks", in: report.text) == report.reviewFallbacks.items)
  }

  @Test(
    "a classified run whose every review diff-risk rated reports no fallback, and an unreadable return says why — catches a fallback counted for a rated review"
  )
  func reviewFallbacksNoneWhenRated() throws {
    let web = try Self.memos4Return("share-view-limit-web")
    let base = Self.build(events: [
      Self.started("report-export-api"),
      .merge(.init(task: "report-export-api", preCommit: "a", postCommit: "b", at: Self.at)),
    ])
    let rated = RunReportBuild(
      record: base.record, log: base.log,
      returns: [
        "report-export-api": .read(
          Self.noting(
            "review: classified at high by swiftgate judge diff-risk", web,
            task: "report-export-api"))
      ])
    let report = BrownfieldRunReport.make(Self.inputs(build: .read(rated)))
    #expect(report.reviewFallbacks == .init(items: [], note: nil))
    #expect(lines("Review fallbacks", in: report.text) == ["none"])

    let damaged = RunReportBuild(
      record: base.record, log: base.log,
      returns: [
        "report-export-api": .unreadable(
          source: "returns/report-export-api.json", reason: "notes is not a string")
      ])
    #expect(
      BrownfieldRunReport.make(Self.inputs(build: .read(damaged))).reviewFallbacks.items == [
        "report-export-api (merged): review depth unknown: returns/report-export-api.json didn't "
          + "read: notes is not a string"
      ])

    let full = BrownfieldRunReport.make(
      Self.inputs(build: .read(Self.build(review: .full, events: base.log.events))))
    #expect(full.reviewFallbacks == .init(items: [], note: nil))
  }

  /// A return the fifth `usememos/memos` trial's `build-task` workflow handed back.
  private static func memos5Return(_ task: String) throws -> TaskReturn {
    try TaskReturnJSON.decode(Fixture.data("BuildReturn/memos-5/\(task).json"))
  }

  @Test(
    "the report names each reviewed task's depth and what set it: the judge, a sensitive path or a fallback — catches the fifth memos trial's report, which named no depth when diff-risk rated every task"
  )
  func reviewDepthPerTask() throws {
    let tasks = ["share-view-limit-store", "share-view-limit-web", "share-view-limit-api"]
    var returns: [String: RunReportInput<TaskReturn>] = [:]
    for task in tasks { returns[task] = .read(try Self.memos5Return(task)) }
    let store = try Self.memos5Return("share-view-limit-store")
    returns["auth"] = .read(
      Self.noting(
        "Done.\nreview: classified at high because the sensitive glob store/** matches "
          + "store/auth.go", store, task: "auth"))
    returns["legacy"] = .read(try Self.memos4Return("share-view-limit-web"))
    var events: [BuildEvent] = []
    for task in tasks + ["auth", "missing"] {
      events += [
        Self.started(task),
        .merge(.init(task: task, preCommit: "a", postCommit: "b", at: Self.at)),
      ]
    }
    events += [
      Self.started("legacy"),
      .transition(.init(task: "legacy", from: .inProgress, to: .blocked, at: Self.at)),
    ]
    let base = Self.build(events: events)
    let build = RunReportBuild(record: base.record, log: base.log, returns: returns)

    let report = BrownfieldRunReport.make(Self.inputs(build: .read(build)))

    #expect(
      report.reviewDepths.items == [
        "share-view-limit-store (merged): high, as swiftgate judge diff-risk rated it",
        "share-view-limit-web (merged): medium, as swiftgate judge diff-risk rated it",
        "share-view-limit-api (merged): high, as swiftgate judge diff-risk rated it",
        "auth (merged): high, because the sensitive glob store/** matches store/auth.go",
        "missing (merged): unknown, the build run stored no checked return for it",
        "legacy (blocked): medium, because diff-risk gave no level: the clone's config has no "
          + "[judge] section",
      ])
    #expect(report.reviewDepths.note == nil)
    #expect(lines("Review depth", in: report.text) == report.reviewDepths.items)
    #expect(
      !report.reviewFallbacks.items.contains { $0.hasPrefix("auth ") },
      "a sensitive path's depth read as a fallback")

    let object = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
    let section = try #require(object["reviewDepths"] as? [String: Any])
    #expect(section["items"] as? [String] == report.reviewDepths.items)

    let full = BrownfieldRunReport.make(
      Self.inputs(build: .read(Self.build(review: .full, events: events))))
    #expect(full.reviewDepths.items.isEmpty)
    #expect(full.reviewDepths.note == "the preset's review is full, so no task was classified")
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

  /// The second memos trial's ledger and build log: the contract done, 2 tasks blocked, 1
  /// pending, and a GREEN `final` that gated the contract alone.
  private static func memosTrial() throws -> (ledger: Ledger, build: RunReportBuild) {
    let directory = Fixture.directory.appending(path: "RunReport/memos-2")
    let ledger = try LedgerJSON.decode(Data(contentsOf: directory.appending(path: "ledger.json")))
    let log = BuildEventJSON.decode(
      try Data(contentsOf: directory.appending(path: "build-events.jsonl")))
    return (ledger, RunReportBuild(record: build(events: []).record, log: log))
  }

  @Test(
    "a run that left tasks blocked or pending leads with incomplete and names each one, never with final GREEN — catches a report that reads a contract-only final as a finished run"
  )
  func unfinishedRunLeadsIncomplete() throws {
    let trial = try Self.memosTrial()
    let report = BrownfieldRunReport.make(
      Self.inputs(ledger: .read(trial.ledger), build: .read(trial.build)))

    #expect(
      report.unfinishedTasks.items == [
        .init(id: "share-view-limit-store", status: .blocked),
        .init(id: "share-view-limit-api", status: .pending),
        .init(id: "share-view-limit-web", status: .blocked),
      ])
    #expect(report.final?.verdict == .green)
    let text = report.text.split(separator: "\n").map(String.init)
    let first = text.first ?? ""
    #expect(first.hasPrefix("run: INCOMPLETE"), "\(first)")
    #expect(!first.contains("GREEN"), "\(first)")
    for (task, state) in [
      ("share-view-limit-store", "blocked"), ("share-view-limit-api", "pending"),
      ("share-view-limit-web", "blocked"),
    ] {
      #expect(first.contains("\(task) (\(state))"), "\(first)")
      #expect(lines("Unfinished tasks", in: report.text).contains("\(task): \(state)"))
    }
    let second = text.dropFirst().first ?? ""
    #expect(second.hasPrefix("final: GREEN"), "\(second)")
    #expect(second.contains("only what merged"), "\(second)")
  }

  @Test(
    "a ledger that can't be read leaves the run's completeness unknown on the first line — catches a GREEN headline over tasks nobody could count"
  )
  func unreadableLedgerLeadsUnknown() {
    let report = BrownfieldRunReport.make(
      Self.inputs(ledger: .missing(path: "/clone/.git/swift-harness/plans/csv/ledger.json")))
    let first = report.text.split(separator: "\n").first.map(String.init) ?? ""
    #expect(first.hasPrefix("run: completeness unknown"), "\(first)")
    #expect(first.contains("ledger.json"), "\(first)")
    #expect(!first.contains("GREEN"), "\(first)")
    #expect(report.unfinishedTasks.note?.contains("ledger.json") == true)
  }

  @Test(
    "a run whose every task is done says so with an empty unfinished list — catches a finished run reported as incomplete"
  )
  func finishedRunHasNoUnfinishedTasks() {
    let report = BrownfieldRunReport.make(Self.inputs())
    #expect(report.unfinishedTasks == .init(items: [], note: nil))
    #expect(report.text.hasPrefix("final: GREEN"))
    #expect(lines("Unfinished tasks", in: report.text) == ["none"])
  }

  @Test(
    "the JSON lists each unfinished task with its state — catches an incomplete run that only the text admits"
  )
  func unfinishedTasksInJSON() throws {
    let trial = try Self.memosTrial()
    let report = BrownfieldRunReport.make(
      Self.inputs(ledger: .read(trial.ledger), build: .read(trial.build)))
    let data = try JSONEncoder().encode(report)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let section = try #require(object["unfinishedTasks"] as? [String: Any])
    let items = try #require(section["items"] as? [[String: String]])
    #expect(
      items.map { $0["id"] ?? "" } == [
        "share-view-limit-store", "share-view-limit-api", "share-view-limit-web",
      ])
    #expect(items.map { $0["status"] ?? "" } == ["blocked", "pending", "blocked"])
  }

  @Test(
    "a run cut off by its time box leads INCOMPLETE and names its box, each dropped task with why, and the tasks that never started — catches a report that hides the work that didn't fit the box"
  )
  func timeBoxSection() {
    let launch = Date(timeIntervalSince1970: 1_790_000_000)
    let box = RunTimeBox(
      startedAt: launch,
      limits: TimeBoxLimits(
        budgetMin: 45, stopStartsBeforeMin: 13, finalReserveMin: 5, source: .config))
    let base = Self.build(events: [
      .gate(.init(stage: .final, tier: .final, verdict: .green, runID: "gate-1", at: Self.at))
    ])
    let cutoff = CutoffRecord(
      at: launch.addingTimeInterval(40 * 60), timeBox: box,
      decisions: [
        CutoffDecision(task: "api", action: .finishMerge, reason: "its merge fits"),
        CutoffDecision(task: "web", action: .abandon, reason: "still working at the cutoff"),
        CutoffDecision(task: "docs", action: .notStarted, reason: "never started"),
      ])
    let record = base.record
    let build = RunReportBuild(
      record: BuildRunRecord(
        runID: record.runID, plan: record.plan, startedAt: record.startedAt,
        presetName: record.presetName, preset: record.preset, timeBox: box),
      log: base.log, cutoff: .read(cutoff))
    let ledger = Ledger(
      schemaVersion: 1, resume: "r", maxParallel: 3,
      tasks: [("api", TaskStatus.done), ("web", .abandoned), ("docs", .pending)].map {
        LedgerTask(
          id: $0.0, deps: [], writeSet: ["\($0.0)/"], gate: .slice, tests: [], covers: [],
          estLines: 1, status: $0.1, worktree: "../\($0.0)")
      }, waves: [["api", "web", "docs"]])

    let text = BrownfieldRunReport.make(Self.inputs(ledger: .read(ledger), build: .read(build)))
      .text

    #expect(text.hasPrefix("run: INCOMPLETE"), "\(text)")
    let lines = lines("Time box", in: text)
    #expect(lines.first?.contains("45 min") == true, "\(lines)")
    #expect(lines.contains("web didn't fit the box: abandoned, still working at the cutoff"))
    #expect(lines.contains("docs didn't fit the box: never started"))
    #expect(!lines.contains { $0.hasPrefix("api") })
  }

  @Test(
    "a run inside its box says it ended inside it, and an owned run has no time box section — catches a time box line on a run that never had one"
  )
  func timeBoxAbsentOrMet() {
    let launch = Date(timeIntervalSince1970: 1_790_000_000)
    let box = RunTimeBox(
      startedAt: launch,
      limits: TimeBoxLimits(
        budgetMin: 30, stopStartsBeforeMin: 13, finalReserveMin: 5, source: .flag))
    let base = Self.build(events: [
      .gate(.init(stage: .final, tier: .final, verdict: .green, runID: "gate-1", at: Self.at))
    ])
    let record = base.record
    let boxed = RunReportBuild(
      record: BuildRunRecord(
        runID: record.runID, plan: record.plan, startedAt: record.startedAt,
        presetName: record.presetName, preset: record.preset, timeBox: box),
      log: base.log, cutoff: .missing(path: "cutoff.json"))

    let met = BrownfieldRunReport.make(Self.inputs(build: .read(boxed))).text
    let none = BrownfieldRunReport.make(Self.inputs(build: .read(base))).text

    #expect(lines("Time box", in: met).first?.contains("30 min, from --time-box") == true, "\(met)")
    #expect(lines("Time box", in: met).contains("the cutoff never came"), "\(met)")
    #expect(!none.contains("## Time box"))
  }
}

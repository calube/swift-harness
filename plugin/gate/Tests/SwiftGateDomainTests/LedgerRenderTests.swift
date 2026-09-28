import Foundation
import SwiftGateDomain
import Testing

@Suite("Design render — ledger page")
struct LedgerRenderTests {
  static func task(
    id: String, deps: [String] = [], covers: [String] = [], estLines: Int = 10
  ) -> LedgerTask {
    LedgerTask(
      id: id, deps: deps, writeSet: ["Sample/Sources/\(id)/"], gate: .fast, tests: [],
      covers: covers, estLines: estLines, status: .pending, worktree: "../app-\(id)")
  }

  static func ledger(tasks: [LedgerTask], waves: [[String]], maxParallel: Int = 3) -> Ledger {
    Ledger(
      schemaVersion: 1, resume: "planned", maxParallel: maxParallel, tasks: tasks, waves: waves)
  }

  static func design(requirements: [(id: String, statement: String)]) -> DesignDocument {
    let bullets = requirements.map { "- \($0.id): \($0.statement)" }.joined(separator: "\n")
    let text = """
      # Sample

      ## Problem

      Something.

      ## Requirements

      \(bullets)

      ## Decision

      Do it.

      ## Test plan by tier

      - test-sample: it works — tier T1

      """
    return DesignDocument(markdown: .parse(text))
  }

  static func page(
    slug: String = "sample-plan", ledger: Ledger, design: DesignDocument,
    designSha: String = "deadbeef00112233"
  ) -> String {
    LedgerRender.page(.init(slug: slug, ledger: ledger, design: design, designSha: designSha)).html
  }

  // MARK: - Build gates

  static let startedAt = Date(timeIntervalSince1970: 1_790_000_000)

  static func mergeGate(_ task: String, _ verdict: Verdict, run: String, minutes: Double)
    -> BuildEvent
  {
    .gate(
      .init(
        stage: .merge(task: task), tier: .push, verdict: verdict, runID: run,
        at: startedAt.addingTimeInterval(minutes * 60)))
  }

  static func buildView(required: LedgerRender.BuildView.Required = .known(.empty))
    -> LedgerRender.BuildView
  {
    LedgerRender.BuildView(
      runID: "20260927T183225Z-b36f002c", presetName: "interview", timeBudgetMin: 38,
      totalWallMilliseconds: 1_415_000,
      taskGates: ["task-a": TaskReturn.Gate(tier: .fast, verdict: .green, runID: "run-task-a")],
      log: BuildEventLog(
        events: [
          mergeGate("task-a", .red, run: "run-merge-a1", minutes: 5),
          mergeGate("task-a", .green, run: "run-merge-a2", minutes: 9),
          .gate(
            .init(
              stage: .final, tier: .ready, verdict: .red, runID: "run-final",
              at: startedAt.addingTimeInterval(20 * 60))),
        ],
        damage: []),
      required: required)
  }

  @Test(
    "with a build run the page shows each task's task gate and newest merge gate, and the final gate, each with verdict and run id — catches a ledger page that hides what the gates said"
  )
  func buildGatesAreShown() throws {
    let ledger = Self.ledger(tasks: [Self.task(id: "task-a")], waves: [["task-a"]])
    let html = LedgerRender.page(
      .init(
        slug: "sample-plan", ledger: ledger, design: Self.design(requirements: []),
        designSha: "deadbeef00112233", build: Self.buildView())
    ).html

    for text in [
      "run-task-a", "run-merge-a2", "run-final", "20260927T183225Z-b36f002c", "interview",
      "23m 35s", "38 min",
    ] {
      #expect(html.contains(text), "page lacks \(text)")
    }
    #expect(!html.contains("run-merge-a1"))
    #expect(html.contains(#"data-verdict="RED""#))
    #expect(html.contains(#"data-verdict="GREEN""#))
  }

  @Test(
    "without a build run the page has no gate section or gate badges — catches a planned ledger showing gates that never ran"
  )
  func noBuildNoGates() throws {
    let ledger = Self.ledger(tasks: [Self.task(id: "task-a")], waves: [["task-a"]])
    let html = Self.page(ledger: ledger, design: Self.design(requirements: []))

    #expect(!html.contains(#"class="gate""#))
    #expect(!html.contains("Final gate"))
  }

  // MARK: - Requirement × task coverage matrix

  @Test(
    "an uncovered requirement is shown as a visible gap, not colour alone — catches a view hiding a gap"
  )
  func uncoveredRequirementIsAVisibleGap() throws {
    let design = Self.design(requirements: [
      ("req-a", "A survives relaunch"), ("req-b", "B never planned for"),
    ])
    let tasks = [Self.task(id: "task-a", covers: ["req-a"])]
    let html = Self.page(
      ledger: Self.ledger(tasks: tasks, waves: [["task-a"]]), design: design)

    let gapRow = try #require(html.range(of: "data-requirement=\"req-b\""))
    let gapRowEnd = try #require(html[gapRow.upperBound...].range(of: "</tr>"))
    #expect(html[gapRow.lowerBound..<gapRowEnd.upperBound].contains("Gap: no task covers this"))
    #expect(html[gapRow.lowerBound..<gapRowEnd.upperBound].contains("data-gap=\"true\""))

    let coveredRow = try #require(html.range(of: "data-requirement=\"req-a\""))
    let coveredRowEnd = try #require(html[coveredRow.upperBound...].range(of: "</tr>"))
    let coveredSlice = html[coveredRow.lowerBound..<coveredRowEnd.upperBound]
    #expect(!coveredSlice.contains("Gap: no task covers this"))
    #expect(coveredSlice.contains("data-gap=\"false\""))
  }

  @Test(
    "requirement statements are visible; requirement ids reach the page only in data- attributes — catches ids as reader words"
  )
  func requirementTitlesVisibleIdsHidden() throws {
    let design = Self.design(requirements: [("req-survives", "Orders survive a relaunch")])
    let tasks = [Self.task(id: "task-a", covers: ["req-survives"])]
    let html = Self.page(ledger: Self.ledger(tasks: tasks, waves: [["task-a"]]), design: design)
    #expect(html.contains("Orders survive a relaunch"))
    #expect(html.contains("data-requirement=\"req-survives\""))
  }

  // MARK: - Task DAG

  @Test("DAG edges equal deps exactly — catches a rendered edge the ledger never declared")
  func dagEdgesEqualDeps() throws {
    let tasks = [
      Self.task(id: "task-a"),
      Self.task(id: "task-b", deps: ["task-a"]),
      Self.task(id: "task-c", deps: ["task-a", "task-b"]),
    ]
    let source = LedgerRender.dagMermaidSource(tasks: tasks)

    // Node id -> visible label (plain task ids here, so the label is the id unescaped).
    var labelOfNode: [String: String] = [:]
    for match in Self.matches(of: #"n(\d+)\["([^"]*)"\]"#, in: source) {
      labelOfNode[match[1]] = match[2]
    }
    #expect(Set(labelOfNode.values) == Set(tasks.map(\.id)))

    var renderedEdges: Set<[String]> = []
    for match in Self.matches(of: #"n(\d+) --> n(\d+)"#, in: source) {
      let from = try #require(labelOfNode[match[1]])
      let to = try #require(labelOfNode[match[2]])
      renderedEdges.insert([from, to])
    }
    let expectedEdges = Set(tasks.flatMap { task in task.deps.map { [$0, task.id] } })
    #expect(renderedEdges == expectedEdges)
    #expect(renderedEdges.count == expectedEdges.count)
  }

  @Test(
    "a task id containing ], --> and <script> breaks neither the diagram nor the page — catches an injected label reaching the page as markup"
  )
  func maliciousTaskIdCannotBreakOutOrInject() throws {
    let evilID = "evil]-->tag<script>alert(1)</script>"
    let tasks = [
      Self.task(id: "task-a"),
      Self.task(id: evilID, deps: ["task-a"]),
    ]
    let html = Self.page(
      ledger: Self.ledger(tasks: tasks, waves: [["task-a"], [evilID]]),
      design: Self.design(requirements: []))

    #expect(!html.contains("<script>"))
    #expect(!html.contains("</script>"))
    // Exactly one node declaration per task: an injected "]" or "-->" in the id can't spawn or
    // erase a node.
    #expect(Self.matches(of: #"n\d+\["#, in: html).count == tasks.count)
    // Exactly one edge: the injected id's own "-->" text is escaped, so it can't forge a second one.
    #expect(
      Self.matches(of: #" --&gt; "#, in: html).count + Self.matches(of: #" --> "#, in: html).count
        == 1)
  }

  // MARK: - Wave timeline

  @Test(
    "waves render in plan-schedule's recomputed order — catches trusting the ledger's stored order"
  )
  func wavesRenderInRecomputedOrderWhenTheyAgree() throws {
    let tasks = [Self.task(id: "task-a"), Self.task(id: "task-b", deps: ["task-a"])]
    let html = Self.page(
      ledger: Self.ledger(tasks: tasks, waves: [["task-a"], ["task-b"]]),
      design: Self.design(requirements: []))
    #expect(!html.contains("showing the recomputed order below"))
    let waveOne = try #require(html.range(of: "data-wave=\"0\""))
    let waveOneEnd = try #require(html[waveOne.upperBound...].range(of: "</tr>"))
    #expect(html[waveOne.lowerBound..<waveOneEnd.upperBound].contains(">task-a<"))
  }

  @Test(
    "a mismatched stored wave order shows the recomputed order with a visible warning — catches silently trusting either side"
  )
  func mismatchedWavesShowRecomputedOrderAndWarn() throws {
    let tasks = [Self.task(id: "task-a"), Self.task(id: "task-b", deps: ["task-a"])]
    // The ledger's stored waves put the dependent task first; plan-schedule would never do that.
    let html = Self.page(
      ledger: Self.ledger(tasks: tasks, waves: [["task-b"], ["task-a"]]),
      design: Self.design(requirements: []))
    #expect(html.contains("showing the recomputed order below"))
    let waveOne = try #require(html.range(of: "data-wave=\"0\""))
    let waveOneEnd = try #require(html[waveOne.upperBound...].range(of: "</tr>"))
    #expect(html[waveOne.lowerBound..<waveOneEnd.upperBound].contains(">task-a<"))
  }

  @Test(
    "a dependency cycle in the ledger shows an unavailable wave timeline and overhead share instead of hanging or guessing — catches a broken schedule rendered as if it were fine"
  )
  func cyclicScheduleShowsUnavailableSections() throws {
    let tasks = [
      Self.task(id: "task-a", deps: ["task-b"]), Self.task(id: "task-b", deps: ["task-a"]),
    ]
    let html = Self.page(
      ledger: Self.ledger(tasks: tasks, waves: [["task-a"], ["task-b"]]),
      design: Self.design(requirements: []))
    #expect(html.contains("Wave timeline unavailable:"))
    #expect(html.contains("form a dependency cycle"))
    #expect(html.contains("Predicted overhead share"))
    #expect(html.contains("Unavailable:"))
  }

  @Test(
    "a task depending on an id absent from the ledger is named in the unavailable wave timeline — catches a dangling dependency silently dropped"
  )
  func missingDependencyIsNamedInTheUnavailableMessage() throws {
    let tasks = [Self.task(id: "task-a", deps: ["task-ghost"])]
    let html = Self.page(
      ledger: Self.ledger(tasks: tasks, waves: [["task-a"]]),
      design: Self.design(requirements: []))
    #expect(html.contains("task task-a depends on task-ghost, which isn"))
  }

  @Test(
    "a repeated task id renders an unavailable wave timeline naming it, and the DAG and overhead helpers don't trap — catches a hand-edited ledger crashing design-render"
  )
  func duplicateTaskIDRendersUnavailable() async {
    await #expect(processExitsWith: .success) {
      let tasks = [
        LedgerRenderTests.task(id: "task-a", estLines: 10),
        LedgerRenderTests.task(id: "task-a", estLines: 30),
        LedgerRenderTests.task(id: "task-b", deps: ["task-a"]),
      ]
      let html = LedgerRenderTests.page(
        ledger: LedgerRenderTests.ledger(tasks: tasks, waves: [["task-a", "task-a"], ["task-b"]]),
        design: LedgerRenderTests.design(requirements: []))
      #expect(html.contains("Wave timeline unavailable:"))
      #expect(html.contains("task id task-a appears more than once"))
      #expect(LedgerRender.dagMermaidSource(tasks: tasks).contains("-->"))
      #expect(
        LedgerRender.predictedOverheadShare(tasks: tasks, waves: [["task-a"], ["task-b"]]) != nil)
    }
  }

  // MARK: - Predicted overhead share

  @Test("an empty ledger's overhead share reads n/a on the rendered page, not a bogus number")
  func emptyLedgerOverheadShareIsNotAvailable() throws {
    let html = Self.page(
      ledger: Self.ledger(tasks: [], waves: []), design: Self.design(requirements: []))
    #expect(html.contains("n/a (no tasks or no estimated time)"))
  }

  @Test(
    "predicted overhead share compares the schedule's wall time against the DAG's critical path — its own formula, since the spec names none"
  )
  func predictedOverheadShareFormula() throws {
    // Two independent tasks scheduled into the same wave: wall == critical path (each chain is
    // just the one task), so there's no overhead.
    let independent = [Self.task(id: "a", estLines: 100), Self.task(id: "b", estLines: 50)]
    #expect(
      LedgerRender.predictedOverheadShare(tasks: independent, waves: [["a", "b"]]) == 0)

    // A dependency chain across two waves: wall == critical path again, since the chain itself
    // is the whole schedule.
    let chain = [
      Self.task(id: "a", estLines: 100), Self.task(id: "b", deps: ["a"], estLines: 50),
    ]
    #expect(LedgerRender.predictedOverheadShare(tasks: chain, waves: [["a"], ["b"]]) == 0)

    // Two independent, equal-cost tasks forced into separate waves (e.g. maxParallel == 1):
    // wall = 100 + 100 = 200, critical path = 100 (neither depends on the other), so half the
    // predicted wall time is overhead from serialising work that didn't have to be serial.
    let forcedSerial = [Self.task(id: "a", estLines: 100), Self.task(id: "b", estLines: 100)]
    #expect(
      LedgerRender.predictedOverheadShare(tasks: forcedSerial, waves: [["a"], ["b"]]) == 0.5)

    #expect(LedgerRender.predictedOverheadShare(tasks: [], waves: []) == nil)
    let zeroCost = [Self.task(id: "a", estLines: 0)]
    #expect(LedgerRender.predictedOverheadShare(tasks: zeroCost, waves: [["a"]]) == nil)
  }

  @Test("the overhead share section reports a percentage on the rendered page")
  func overheadShareAppearsOnPage() throws {
    // maxParallel forces the two independent, equal-cost tasks into separate recomputed waves,
    // matching the forced-serial case `predictedOverheadShareFormula` checks directly.
    let tasks = [Self.task(id: "a", estLines: 100), Self.task(id: "b", estLines: 100)]
    let html = Self.page(
      ledger: Self.ledger(tasks: tasks, waves: [["a"], ["b"]], maxParallel: 1),
      design: Self.design(requirements: []))
    #expect(html.contains("50% predicted overhead"))
  }

  // MARK: - Reuse

  @Test("the ledger page reuses the shared shell and escaper — catches a second page contract")
  func reusesSharedShell() throws {
    let html = Self.page(
      ledger: Self.ledger(tasks: [Self.task(id: "a")], waves: [["a"]]),
      design: Self.design(requirements: []))
    #expect(html.hasPrefix("<title>Ledger: sample-plan</title>"))
    #expect(html.contains("<pre class=\"mermaid\">"))
    #expect(LedgerRender.capabilities.isEmpty)
  }

  // MARK: - Helpers

  static func matches(of p: String, in text: String) -> [[String]] {
    let regex = try! NSRegularExpression(pattern: p)  // swiftgate:allow safety.try-bang — literal
    let range = NSRange(text.startIndex..., in: text)
    return regex.matches(in: text, range: range).map { match in
      (0..<match.numberOfRanges).map { index in
        guard let r = Range(match.range(at: index), in: text) else { return "" }
        return String(text[r])
      }
    }
  }
}

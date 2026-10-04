import Foundation
import SwiftGateDomain
import Testing

/// A plan in the brownfield `PLAN.md` shape: 3 tasks in 2 waves, with an unrelated `###`
/// heading and an assumptions section.
private let threeTaskPlan = """
  # Search filters

  ## Assumptions
  - "Recent" means the last 7 days, since the spec gives no window.
  - Filters combine with AND.

  ## Tasks

  ### Merge points
  Nothing here is a task.

  ### `filter-model`
  Search results carry the filter they matched.
  - Deps: none · Gate: slice · Model: opus · estLines: 120
  - Why: The view needs to know which filter matched (design §4.2).
  - Scope: the filter enum and its parsing
  - Acceptance:
    - `parsesRecent` fails first
    - the slice gate passes
  - Out of scope: persisting filters
  - Writes: `api/filters/`, `api/tests/test_filters.py`
  - Does: adds the enum.
  - Tests: parsesRecent.

  ### `filter-endpoint`
  The search endpoint accepts a filter.
  - Deps: none · Gate: slice · estLines: 80
  - Why: Clients send filters by query string.
  - Writes: `api/routes/search.py`

  ### `filter-ui`
  The search screen shows filter chips.
  - Deps: `filter-model`, `filter-endpoint` · Gate: slice · Model: sonnet · estLines: 200
  - Why: Users pick a filter without typing (§5).
  - Scope:
    - the chip row
    - its selection state
  - Writes: `web/src/search/`
  """

private func section(_ id: String, writes: String? = "`src/a.ts`", gate: String = "slice")
  -> String
{
  var lines = [
    "### `\(id)`", "Does a thing.", "- Deps: none · Gate: \(gate) · estLines: 10",
    "- Why: Because.",
  ]
  if let writes { lines.append("- Writes: \(writes)") }
  return lines.joined(separator: "\n")
}

@Suite("Live plan")
struct LivePlanTests {
  @Test(
    "a plan with 3 tasks and 2 waves derives the ledger the executor reads — catches a dropped dependency"
  )
  func threeTasksTwoWaves() throws {
    let plan = try LivePlanParser.parse(threeTaskPlan)
    let ledger = try plan.ledger(maxParallel: 3, existing: nil) { "worktrees/\($0)" }
    let read = try LedgerJSON.decode(try LedgerJSON.encode(ledger))

    #expect(read.tasks.map(\.id) == ["filter-model", "filter-endpoint", "filter-ui"])
    #expect(read.waves == [["filter-endpoint", "filter-model"], ["filter-ui"]])
    let ui = try #require(read.tasks.first { $0.id == "filter-ui" })
    #expect(ui.deps == ["filter-model", "filter-endpoint"])
    #expect(ui.writeSet == ["web/src/search/"])
    #expect(ui.gate == .slice)
    #expect(ui.model == .sonnet)
    #expect(ui.estLines == 200)
    #expect(ui.status == .pending)
    #expect(ui.worktree == "worktrees/filter-ui")
    let model = try #require(read.tasks.first { $0.id == "filter-model" })
    #expect(model.writeSet == ["api/filters/", "api/tests/test_filters.py"])
    #expect(model.model == .opus)
    #expect(read.tasks.first { $0.id == "filter-endpoint" }?.model == nil)
    #expect(read.maxParallel == 3)
    #expect(read.resume == "planned; 3 tasks in 2 waves; next: build the first wave")
  }

  @Test(
    "each task's goal, why, scope, acceptance and out of scope become its brief — catches a brief the viewer can't show"
  )
  func briefs() throws {
    let plan = try LivePlanParser.parse(threeTaskPlan)
    let model = try #require(plan.tasks.first { $0.id == "filter-model" })
    #expect(
      model.brief
        == TaskBrief(
          title: "Search results carry the filter they matched.",
          why: "The view needs to know which filter matched (design §4.2).", designRef: "§4.2",
          scope: ["the filter enum and its parsing"],
          acceptance: ["`parsesRecent` fails first", "the slice gate passes"],
          outOfScope: ["persisting filters"]))
    let endpoint = try #require(plan.tasks.first { $0.id == "filter-endpoint" })
    #expect(endpoint.brief.designRef == nil)
    #expect(endpoint.brief.scope.isEmpty)
    #expect(
      plan.tasks.first { $0.id == "filter-ui" }?.brief.scope == [
        "the chip row", "its selection state",
      ])
    #expect(
      plan.assumptions == [
        "\"Recent\" means the last 7 days, since the spec gives no window.",
        "Filters combine with AND.",
      ])
  }

  @Test(
    "the live plan.json carries every brief and reads back — catches briefs lost on the way to the viewer"
  )
  func planFileRoundTrip() throws {
    let plan = try LivePlanParser.parse(threeTaskPlan)
    let file = plan.planFile(slug: "search-filters", resume: "planned", existing: nil)
    let read = try? PlanFileJSON.decode(try PlanFileJSON.encode(file))

    #expect(read == file)
    let source = try #require(read?.livePlanSource)
    #expect(source.path == "PLAN.md")
    #expect(source.briefs.keys.sorted() == ["filter-endpoint", "filter-model", "filter-ui"])
    #expect(source.briefs["filter-ui"]?.title == "The search screen shows filter chips.")
    #expect(read?.designSource == nil)
  }

  @Test(
    "a task with no Writes line fails naming the task — catches a task the executor can't scope")
  func noWrites() {
    let text = section("first") + "\n\n" + section("second", writes: nil)
    #expect(throws: LivePlanError.noWrites(task: "second")) { try LivePlanParser.parse(text) }
  }

  @Test(
    "an owned-profile gate fails naming the task — catches a push gate a brownfield clone can't run"
  )
  func pushGate() {
    #expect(throws: LivePlanError.ownedProfileGate(task: "only", tier: .push)) {
      try LivePlanParser.parse(section("only", gate: "push"))
    }
    #expect(throws: LivePlanError.unknownGate(task: "only", value: "fastest")) {
      try LivePlanParser.parse(section("only", gate: "fastest"))
    }
  }

  @Test(
    "a dependency on a task the plan lacks fails naming both — catches a ledger the executor would stall on"
  )
  func missingDependency() throws {
    let text = section("only").replacingOccurrences(of: "Deps: none", with: "Deps: `ghost`")
    let plan = try LivePlanParser.parse(text)
    #expect(throws: LivePlanError.missingDependency(task: "only", dependency: "ghost")) {
      try plan.ledger(maxParallel: 2, existing: nil) { $0 }
    }
  }

  @Test("a plan with no task sections fails — catches an empty ledger that looks finished")
  func noTasks() {
    #expect(throws: LivePlanError.noTasks) {
      try LivePlanParser.parse("# Plan\n\n## Assumptions\n- one\n")
    }
  }

  @Test("a re-import keeps each kept task's status and branch — catches a reset of work in flight")
  func reimportKeepsStatus() throws {
    let plan = try LivePlanParser.parse(threeTaskPlan)
    let first = try plan.ledger(maxParallel: 3, existing: nil) { "worktrees/\($0)" }
    let started = first.tasks.map { task in
      task.id == "filter-model"
        ? LedgerTask(
          id: task.id, deps: task.deps, writeSet: task.writeSet, gate: task.gate,
          tests: task.tests, covers: task.covers, estLines: task.estLines, status: .inProgress,
          worktree: "elsewhere", model: task.model, branch: "search-filters/filter-model")
        : task
    }
    let existing = Ledger(
      schemaVersion: 1, resume: first.resume, maxParallel: 3, tasks: started, waves: first.waves)
    let second = try plan.ledger(maxParallel: 3, existing: existing) { "worktrees/\($0)" }
    let model = try #require(second.tasks.first { $0.id == "filter-model" })
    #expect(model.status == .inProgress)
    #expect(model.branch == "search-filters/filter-model")
    #expect(model.worktree == "elsewhere")
    #expect(second.tasks.first { $0.id == "filter-ui" }?.status == .pending)
  }

  @Test("the exclude line is added once — catches a line appended on every import")
  func excludeOnce() throws {
    let once = try #require(LivePlanExclude.adding(to: "# git ls-files --others\n*.log"))
    #expect(once == "# git ls-files --others\n*.log\n/PLAN.md\n")
    #expect(LivePlanExclude.adding(to: once) == nil)
    #expect(LivePlanExclude.adding(to: nil) == "/PLAN.md\n")
  }
}

import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// The captured build run under `Fixtures/RunView/build-run-1`, read as the reader hands it over:
/// every store's events from the run's start on, the ledger, the run's join and its spec page.
private struct CapturedRun {
  static let directory = "RunView/build-run-1"

  let ledger: Ledger
  let join: BuildJoin.Run
  let events: [HarnessEvent]
  let requirements: [RunViewRequirement]

  init() throws {
    let ledger = try LedgerJSON.decode(try Fixture.data("\(Self.directory)/ledger.json"))
    let record = try BuildRunJSON.decode(try Fixture.data("\(Self.directory)/run.json"))
    let log = BuildEventJSON.decode(try Fixture.data("\(Self.directory)/ledger-events.jsonl"))
    var returns: [String: TaskReturn] = [:]
    for name in try Self.files(in: "returns", suffix: ".json") {
      let taskReturn = try TaskReturnJSON.decode(try Fixture.data(name))
      returns[taskReturn.task] = taskReturn
    }
    var streams = try Self.files(in: "events", suffix: ".jsonl")
    for store in try Self.directories(in: "events/imported") {
      streams += try Self.files(in: "events/imported/\(store)", suffix: ".jsonl")
    }
    var events: [HarnessEvent] = []
    for stream in streams {
      events += try HarnessEventJSON.decode(try Fixture.data(stream)).events
    }
    guard case .parsed(let page) = SpecPage.parse(try Fixture.text("\(Self.directory)/plan.md"))
    else {
      throw CapturedRunError.specPageMalformed
    }
    self.ledger = ledger
    self.join = BuildJoin.Run(
      plan: record.plan, runID: record.runID,
      writeSets: Dictionary(uniqueKeysWithValues: ledger.tasks.map { ($0.id, $0.writeSet) }),
      returns: returns, events: log.events, record: record)
    self.events = events.filter { $0.time >= record.startedAt }
    self.requirements = RunViewRequirements.from(specPage: page)
  }

  var input: RunViewInput {
    RunViewInput(
      buildRun: join.runID, events: events, join: join, ledger: ledger,
      requirements: requirements)
  }

  func usage(of task: String) -> [AgentUsageEvent] {
    events.compactMap {
      guard case .agentUsage(let usage) = $0.payload, usage.task == task else { return nil }
      return usage
    }
  }

  private static func entries(in relative: String) throws -> [String] {
    try FileManager.default.contentsOfDirectory(
      atPath: Fixture.directory.appending(path: "\(directory)/\(relative)").path
    ).sorted()
  }

  private static func files(in relative: String, suffix: String) throws -> [String] {
    try entries(in: relative).filter { $0.hasSuffix(suffix) }.map {
      "\(directory)/\(relative)/\($0)"
    }
  }

  private static func directories(in relative: String) throws -> [String] {
    try entries(in: relative).filter { !$0.hasPrefix(".") }
  }
}

private enum CapturedRunError: Error {
  case specPageMalformed
}

private let core = "counter-core-reset-and-decrement-floor"
private let button = "counter-ui-reset-button"
private let snapshot = "counter-ui-reset-button-snapshot"

private func time(_ text: String) throws -> Date {
  try Date(text, strategy: .iso8601)
}

private func contains(_ outer: RunView.Span, _ inner: RunView.Span) -> Bool {
  guard inner.start >= outer.start else { return false }
  guard let outerEnd = outer.end else { return true }
  guard let innerEnd = inner.end else { return false }
  return innerEnd <= outerEnd
}

@Suite("run view builder")
struct RunViewBuilderTests {
  @Test("the run carries its plan, preset, start and end — catches a run the header can't name")
  func runHeader() throws {
    let run = try CapturedRun()
    let view = RunViewBuilder.build(run.input)
    #expect(view.run.id == "20261004T045528Z-58d28c78")
    #expect(view.run.plan == "2026-10-03-counter-reset-and-floor")
    #expect(view.run.preset == "capture")
    #expect(try view.run.startedAt == time("2026-10-04T04:55:28Z"))
    #expect(view.run.state == .done)
    let last = run.events.map(\.time).max()
    #expect(view.run.endedAt == last)
    let span = try #require(view.spans.first { $0.phase == .run })
    #expect(span.start == view.run.startedAt)
    #expect(span.end == last)
    #expect(span.outcome == .ok)
  }

  @Test(
    "every task span sits inside the run span and each gate span inside its task's — catches a gate joined to the wrong task"
  )
  func spansNest() throws {
    let view = RunViewBuilder.build(try CapturedRun().input)
    let runSpan = try #require(view.spans.first { $0.phase == .run })
    let taskSpans = view.spans.filter { $0.phase == .task }
    #expect(Set(taskSpans.compactMap(\.task)) == [core, button, snapshot])
    for span in taskSpans {
      #expect(contains(runSpan, span), "\(span.id)")
    }
    let coreSpan = try #require(taskSpans.first { $0.task == core })
    #expect(try coreSpan.start == time("2026-10-04T04:55:47Z"))
    #expect(try coreSpan.end == time("2026-10-04T05:00:29Z"))
    #expect(coreSpan.outcome == .ok)
    #expect(taskSpans.first { $0.task == snapshot }?.outcome == .abandoned)

    let joined: [String: String] = [
      "20261004T045901Z-e384a82a": core,
      "20261004T050310Z-ed998508": button,
      "20261004T051053Z-7447d956": button,
    ]
    for (gateRun, task) in joined {
      let gate = try #require(view.spans.first { $0.phase == .gate && $0.gateRun == gateRun })
      #expect(gate.task == task, "\(gateRun)")
      let taskSpan = try #require(taskSpans.first { $0.task == task })
      #expect(contains(taskSpan, gate), "\(gateRun)")
    }
    let red = try #require(
      view.spans.first { $0.phase == .gate && $0.gateRun == "20261004T050310Z-ed998508" })
    #expect(red.outcome == .red)
    #expect(try red.end == time("2026-10-04T05:05:19.169Z"))
    let redEnd = try time("2026-10-04T05:05:19.169Z")
    #expect(red.start == redEnd.addingTimeInterval(-128.593))

    let merges = view.spans.filter { $0.phase == .merge }
    #expect(merges.filter { $0.task == button }.count == 2)
    for merge in merges {
      let taskSpan = try #require(taskSpans.first { $0.task == merge.task })
      #expect(contains(taskSpan, merge), "\(merge.id)")
    }
    #expect(Set(view.spans.map(\.id)).count == view.spans.count)
    let ids = Set(view.spans.map(\.id))
    for span in view.spans {
      if let parent = span.parent { #expect(ids.contains(parent), "\(span.id)") }
    }

    let finalGate = try #require(view.gates.first { $0.runID == "20261004T051601Z-46b2b09c" })
    #expect(finalGate.task == nil)
    #expect(view.gates.first { $0.runID == "20261004T045901Z-e384a82a" }?.task == core)
  }

  @Test(
    "steps without a start offset are approximate and laid end to end from their gate's start — catches steps stacked at 1 instant"
  )
  func stepsLaidEndToEnd() throws {
    let view = RunViewBuilder.build(try CapturedRun().input)
    let gateRun = "20261004T045901Z-e384a82a"
    let gate = try #require(view.spans.first { $0.phase == .gate && $0.gateRun == gateRun })
    let steps = view.spans.filter { $0.phase == .step && $0.gateRun == gateRun }
    let row = try #require(view.gates.first { $0.runID == gateRun })
    #expect(steps.count == row.steps.count)
    #expect(steps.count > 2)
    #expect(steps.allSatisfy { $0.approximate })
    #expect(steps.first?.start == gate.start)
    for (previous, next) in zip(steps, steps.dropFirst()) {
      #expect(next.start == previous.end, "\(next.id)")
    }
    for step in steps {
      #expect(contains(gate, step), "\(step.id)")
    }
    let tiers = view.spans.filter { $0.phase == .tier && $0.gateRun == gateRun }
    #expect(!tiers.isEmpty)
    for step in steps where step.parent != gate.id {
      let tier = try #require(tiers.first { $0.id == step.parent })
      #expect(contains(tier, step), "\(step.id)")
    }
  }

  @Test(
    "a step with a start offset sits at it and isn't approximate — catches an offset the builder ignores"
  )
  func stepAtItsOffset() throws {
    let start = try time("2026-10-04T05:00:00Z")
    let runEvent = HarnessEvent(
      eventID: "g", time: start.addingTimeInterval(10), runID: "gate-1",
      source: HarnessEventSource(route: .check),
      payload: .gateRun(
        GateRunEvent(
          command: "check push", verdict: .green, milliseconds: 10_000, treeHash: nil,
          dirty: false, tiers: [GateRunTier(tier: .t0, verdict: .green, milliseconds: 4_000)],
          ruleCounts: [:], findingPaths: [], findingPathsTruncated: false, allowanceCounts: [:],
          testCounts: nil)))
    let stepEvent = HarnessEvent(
      eventID: "s", parentID: "g", time: start.addingTimeInterval(10), runID: "gate-1",
      source: HarnessEventSource(route: .check),
      payload: .gateStep(
        GateStepEvent(
          GateStepTiming(
            step: .lint, tier: .t0, milliseconds: 1_000, verdict: .green, derivedData: .none,
            startMs: 3_000))))
    let view = RunViewBuilder.build(
      RunViewInput(buildRun: "b", events: [runEvent, stepEvent]))
    let step = try #require(view.spans.first { $0.phase == .step })
    #expect(!step.approximate)
    #expect(step.start == start.addingTimeInterval(3))
    #expect(step.end == start.addingTimeInterval(4))
    #expect(view.gates.first?.steps.first?.startMs == 3_000)
  }

  @Test(
    "a task's tokens equal the sum of its agent.usage events, an event read from 2 stores counting once — catches double counting"
  )
  func tokensPerTask() throws {
    let run = try CapturedRun()
    var input = run.input
    let usage = run.events.filter { $0.kind == .agentUsage }
    input.events += usage
    let view = RunViewBuilder.build(input)
    for task in [core, button, snapshot] {
      let events = run.usage(of: task)
      #expect(!events.isEmpty)
      let expected = RunView.Tokens(
        input: events.map(\.inputTokens).reduce(0, +),
        output: events.map(\.outputTokens).reduce(0, +),
        cacheRead: events.map(\.cacheReadTokens).reduce(0, +),
        cacheWrite: events.map(\.cacheCreationTokens).reduce(0, +))
      #expect(view.tasks.first { $0.id == task }?.tokens == expected, "\(task)")
    }
    let workers = try #require(view.roles.first { $0.role == .buildWorker })
    let all = [core, button, snapshot].flatMap(run.usage(of:))
    #expect(workers.tokens.output == all.map(\.outputTokens).reduce(0, +))
    #expect(view.roles.map(\.role) == [.orchestrator, .buildWorker])
  }

  @Test("a running task's tokens are null — catches a running worker shown as 0 tokens")
  func runningTaskTokensPending() throws {
    let run = try CapturedRun()
    var input = run.input
    let ledger = run.ledger
    input.ledger = Ledger(
      schemaVersion: ledger.schemaVersion, resume: ledger.resume,
      maxParallel: ledger.maxParallel,
      tasks: ledger.tasks.map { task in
        LedgerTask(
          id: task.id, deps: task.deps, writeSet: task.writeSet, gate: task.gate,
          tests: task.tests, covers: task.covers, estLines: task.estLines,
          status: task.id == snapshot ? .inProgress : task.status, worktree: task.worktree,
          model: task.model, branch: task.branch)
      }, waves: ledger.waves)
    let view = RunViewBuilder.build(input)
    #expect(view.tasks.first { $0.id == snapshot }?.tokens == nil)
    #expect(view.tasks.first { $0.id == core }?.tokens != nil)
  }

  @Test("no RunView string holds a task's worktree path — catches the ledger's worktree leaking")
  func worktreeDropped() throws {
    let run = try CapturedRun()
    let view = RunViewBuilder.build(run.input)
    let json = String(decoding: try RunViewJSON.encode(view), as: UTF8.self)
    #expect(view.tasks.count == run.ledger.tasks.count)
    for task in run.ledger.tasks {
      #expect(!json.contains(task.worktree), "\(task.id)")
      #expect(!json.contains("app-\(run.join.plan)"), "\(task.id)")
    }
  }

  @Test(
    "each task carries its ledger deps, writes, gate and covers, its first event and its last merge — catches a field the board and graph read empty"
  )
  func taskShape() throws {
    let run = try CapturedRun()
    let view = RunViewBuilder.build(run.input)
    #expect(view.tasks.map(\.id) == run.ledger.tasks.map(\.id))
    for entry in run.ledger.tasks {
      let task = try #require(view.tasks.first { $0.id == entry.id })
      #expect(task.deps == entry.deps)
      #expect(task.writes == entry.writeSet)
      #expect(task.gate == entry.gate)
      #expect(task.covers == entry.covers)
      #expect(task.status == entry.status)
      #expect(task.model == entry.model)
    }
    let buttonTask = try #require(view.tasks.first { $0.id == button })
    #expect(try buttonTask.createdAt == time("2026-10-04T05:01:05Z"))
    #expect(try buttonTask.mergedAt == time("2026-10-04T05:10:53Z"))
    #expect(buttonTask.gateRun == "20261004T050121Z-5816b123")
    #expect(buttonTask.mergeGateRun == "20261004T051053Z-7447d956")
    #expect(buttonTask.commits == ["92b21b0"])
    let snapshotTask = try #require(view.tasks.first { $0.id == snapshot })
    #expect(snapshotTask.mergedAt == nil)
    #expect(snapshotTask.mergeGateRun == nil)
  }

  @Test(
    "a requirement no task covers shows with no tasks and every title is cut to 120 bytes — catches an uncovered requirement dropped"
  )
  func specRows() throws {
    let run = try CapturedRun()
    #expect(
      run.requirements.map(\.id) == [
        "slice-1-reset-after-increments-shows-zero", "slice-2-decrement-at-zero-stays-zero",
      ])
    #expect(
      run.requirements.first?.title
        == "Tapping reset after incrementing twice shows a count of 0.")
    var input = run.input
    let long = String(repeating: "é", count: 100)
    input.requirements.append(RunViewRequirement(id: "req-orphan", title: long))
    let view = RunViewBuilder.build(input)
    #expect(view.spec.map(\.id) == run.requirements.map(\.id) + ["req-orphan"])
    #expect(view.spec.first?.tasks == [core, button, snapshot])
    #expect(view.spec.last?.tasks == [])
    let title = try #require(view.spec.last?.title)
    #expect(title.utf8.count == RunView.maxTitleBytes)
    #expect(long.hasPrefix(title))
  }

  @Test(
    "a brief string holding a newline drops out as 1 damage row and the rest of the brief stays — catches 1 bad line failing the report"
  )
  func briefGuarded() throws {
    var input = try CapturedRun().input
    let long = String(repeating: "a", count: 600)
    input.briefs = [
      core: RunView.Brief(
        title: "Reset and floor", why: long, designRef: "§2",
        scope: ["reducer", "first\nsecond"], acceptance: ["resetAfterIncrementsShowsZero"],
        outOfScope: ["~/notes"])
    ]
    let view = RunViewBuilder.build(input)
    let brief = try #require(view.tasks.first { $0.id == core }?.brief)
    #expect(brief.title == "Reset and floor")
    #expect(brief.why.utf8.count == RunView.maxBriefBytes)
    #expect(brief.designRef == "§2")
    #expect(brief.scope == ["reducer"])
    #expect(brief.acceptance == ["resetAfterIncrementsShowsZero"])
    #expect(brief.outOfScope == [])
    #expect(view.damage.count == 2)
    #expect(view.damage.allSatisfy { $0.source.contains(core) })
    #expect(view.damage.contains { $0.reason.contains("scope") && $0.reason.contains("newline") })
    #expect(view.tasks.first { $0.id == button }?.brief == nil)
  }

  @Test("a halt runs from build.halt to its resume — catches a resolved halt shown as open")
  func halts() throws {
    let view = RunViewBuilder.build(try CapturedRun().input)
    let at = try time("2026-10-04T05:14:05.299Z")
    #expect(
      view.halts == [
        RunView.Halt(task: snapshot, reason: .question, at: at, answer: .abandon, waitMs: 98046)
      ])
  }

  @Test("the reader's damage reaches the view — catches an unreadable file shown as a silent gap")
  func damageKept() throws {
    var input = try CapturedRun().input
    input.damage = [RunView.Damage(source: "events/gate.jsonl", reason: "line 3: not JSON")]
    #expect(RunViewBuilder.build(input).damage == input.damage)
  }
}

import Foundation
import SwiftGateDomain
import Testing

@Suite("a brownfield run's time box")
struct RunTimeBoxTests {
  static let launch = Date(timeIntervalSince1970: 1_790_000_000)

  static func preset(budget: Int, reserve: Int) -> BuildPreset {
    BuildPreset(
      designTier: .none, maxParallel: 3, review: .classified, taskGate: .tier(.slice),
      mergeGate: .merge, workerModel: .claudeSonnet55, timeBudgetMin: budget,
      stopStartsBeforeMin: reserve, onDesignConflict: .amend, taskProof: .prove, stallMin: 2)
  }

  static func box(budget: Int = 45, reserve: Int = 13, final: Int = 5) -> RunTimeBox {
    RunTimeBox(
      startedAt: launch,
      limits: TimeBoxLimits(
        budgetMin: budget, stopStartsBeforeMin: reserve, finalReserveMin: final, source: .config))
  }

  static func minutes(_ value: Double) -> Date { launch.addingTimeInterval(value * 60) }

  @Test(
    "a preset with no budget still gets the 45-minute box and says so, and a configured box keeps its own minutes — catches a brownfield run with no budget"
  )
  func noBudgetGetsTheDefaultBox() {
    let unbounded = TimeBoxLimits.resolve(preset: Self.preset(budget: 0, reserve: 0), override: nil)
    let missing = TimeBoxLimits.resolve(preset: nil, override: nil)
    let configured = TimeBoxLimits.resolve(
      preset: Self.preset(budget: 60, reserve: 15), override: nil)

    #expect(
      unbounded.limits
        == TimeBoxLimits(
          budgetMin: 45, stopStartsBeforeMin: 13, finalReserveMin: 5, source: .default))
    #expect(unbounded.note?.contains("time_budget_min is 0") == true, "\(unbounded.note ?? "")")
    #expect(missing.limits.budgetMin == 45)
    #expect(missing.limits.source == .default)
    #expect(
      configured
        == TimeBoxLimits.Resolution(
          limits: TimeBoxLimits(
            budgetMin: 60, stopStartsBeforeMin: 15, finalReserveMin: 5, source: .config),
          note: nil))
  }

  @Test(
    "--time-box replaces the preset's minutes and clamps both reserves inside a box shorter than them — catches an override whose starts stop after its box ends"
  )
  func overrideClampsTheReserves() {
    let preset = Self.preset(budget: 45, reserve: 13)

    let longer = TimeBoxLimits.resolve(preset: preset, override: 90)
    let short = TimeBoxLimits.resolve(preset: preset, override: 10)
    let tiny = TimeBoxLimits.resolve(preset: preset, override: 3)

    #expect(
      longer.limits
        == TimeBoxLimits(budgetMin: 90, stopStartsBeforeMin: 13, finalReserveMin: 5, source: .flag)
    )
    #expect(
      short.limits
        == TimeBoxLimits(budgetMin: 10, stopStartsBeforeMin: 10, finalReserveMin: 5, source: .flag)
    )
    #expect(
      tiny.limits
        == TimeBoxLimits(budgetMin: 3, stopStartsBeforeMin: 3, finalReserveMin: 3, source: .flag))
  }

  @Test(
    "the box reads normal until starts stop at 32 minutes, no-new-starts until the cutoff at 40, and cutoff after — catches a cutoff at the box's end that leaves final no time inside it"
  )
  func phasesInsideTheBox() {
    let box = Self.box()

    #expect(box.phase(at: Self.minutes(31.9)) == .normal)
    #expect(box.phase(at: Self.minutes(32)) == .noNewStarts)
    #expect(box.phase(at: Self.minutes(39.9)) == .noNewStarts)
    #expect(box.phase(at: Self.minutes(40)) == .cutoff)
    #expect(box.phase(at: Self.minutes(50)) == .cutoff)
  }

  @Test(
    "the early phases' deadlines fall at 5, 8 and 12 minutes and never after starts stop — catches a plan or contract budget that eats the build's window"
  )
  func earlyDeadlines() {
    let full = Self.box().deadlines
    let short = Self.box(budget: 15, reserve: 10, final: 5).deadlines

    #expect(
      full
        == RunTimeBox.Deadlines(
          exploreBy: Self.minutes(5), planBy: Self.minutes(8), contractBy: Self.minutes(12),
          noNewStartsAt: Self.minutes(32), cutoffAt: Self.minutes(40), endsAt: Self.minutes(45)))
    #expect(short.exploreBy == Self.minutes(5))
    #expect(short.planBy == Self.minutes(5))
    #expect(short.contractBy == Self.minutes(5))
    #expect(short.endsAt == Self.minutes(15))
  }

  @Test(
    "at the cutoff the first gating task finishes its merge, a second whose merge no longer fits and a working task are abandoned with why, and a pending task stays as it is — catches a cutoff that asks, or that drops a merge that fits"
  )
  func cutoffDecidesByRule() throws {
    let tasks = [
      CutoffTask(id: "store", stage: .gating), CutoffTask(id: "web", stage: .working),
      CutoffTask(id: "api", stage: .gating), CutoffTask(id: "docs", stage: .notStarted),
    ]

    let decisions = CutoffRule.decide(tasks: tasks, timeBox: Self.box(), now: Self.minutes(40))

    try #require(decisions.map(\.task) == ["store", "web", "api", "docs"])
    #expect(
      decisions.map(\.action) == [.finishMerge, .abandon, .abandon, .notStarted])
    #expect(decisions[1].reason.contains("still working"), "\(decisions[1].reason)")
    #expect(decisions[2].reason.contains("doesn't fit"), "\(decisions[2].reason)")
    #expect(decisions[2].reason.contains("180 s left"), "\(decisions[2].reason)")
    #expect(decisions[3].reason.contains("never started"), "\(decisions[3].reason)")
  }

  @Test(
    "a gating task past the point where its merge and final fit is abandoned too — catches a merge that runs final past the box's end"
  )
  func lateGatingTaskAbandoned() {
    let decisions = CutoffRule.decide(
      tasks: [CutoffTask(id: "store", stage: .gating)], timeBox: Self.box(),
      now: Self.minutes(41))

    #expect(decisions.map(\.action) == [.abandon])
  }

  @Test(
    "the same elapsed time reads cutoff for an owned preset only at its time_budget_min from build start, and for a brownfield box at its cutoff from launch — catches the owned cutoff behaviour changing, or a box measured from build start"
  )
  func schedulerPhaseByProfile() {
    let ledger = Ledger(
      schemaVersion: 1, resume: "r", maxParallel: 3,
      tasks: [
        LedgerTask(
          id: "a", deps: [], writeSet: ["a/"], gate: .slice, tests: [], covers: [], estLines: 1,
          status: .pending, worktree: "../a", model: nil)
      ], waves: [["a"]])
    let owned = BuildPreset(
      designTier: .standard, maxParallel: 3, review: .full, taskGate: .ledger, mergeGate: .push,
      workerModel: .sonnet, timeBudgetMin: 45, stopStartsBeforeMin: 7, onDesignConflict: .block)
    let buildStart = Self.minutes(10)

    func phase(_ preset: BuildPreset, at minute: Double, box: RunTimeBox?) -> BudgetPhase {
      BuildScheduler.next(
        ledger: ledger, running: [], preset: preset, startedAt: buildStart,
        now: Self.minutes(minute), required: .empty, timeBox: box
      ).phase
    }

    #expect(phase(owned, at: 47, box: nil) == .normal)
    #expect(phase(owned, at: 48, box: nil) == .noNewStarts)
    #expect(phase(owned, at: 55, box: nil) == .cutoff)
    let brownfield = Self.preset(budget: 45, reserve: 13)
    #expect(phase(brownfield, at: 32, box: Self.box()) == .noNewStarts)
    #expect(phase(brownfield, at: 40, box: Self.box()) == .cutoff)
    let started = BuildScheduler.next(
      ledger: ledger, running: [], preset: brownfield, startedAt: buildStart,
      now: Self.minutes(40), required: .empty, timeBox: Self.box())
    #expect(started.toStart.isEmpty)
  }

  @Test(
    "a task already merged is never abandoned at the cutoff: with no time left its merge finishes, and one merged with a GREEN gate takes no merge gate's time from a gating task behind it — catches a cutoff that strands a merge it can't take back"
  )
  func mergedTaskFinishes() throws {
    let tasks = [
      CutoffTask(id: "store", stage: .landed), CutoffTask(id: "api", stage: .gating),
      CutoffTask(id: "web", stage: .merged),
    ]

    let early = CutoffRule.decide(tasks: tasks, timeBox: Self.box(), now: Self.minutes(40))
    let late = CutoffRule.decide(tasks: tasks, timeBox: Self.box(), now: Self.minutes(44))

    try #require(early.map(\.task) == ["store", "api", "web"])
    #expect(early.map(\.action) == [.finishMerge, .abandon, .finishMerge])
    #expect(early[1].reason.contains("180 s left"), "\(early[1].reason)")
    #expect(late.map(\.action) == [.finishMerge, .abandon, .finishMerge])
  }
}

@Suite("the cutoff in the third iOS validation trial")
struct CapturedCutoffTests {
  static let fixtures = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Fixtures/BrownfieldTrial")
  static let task = "confirm-downloads-setting"

  /// The run's events up to the cutoff's own `abandoned` transition: what `build cutoff` read.
  static func eventsBeforeCutoff() throws -> [BuildEvent] {
    let log = BuildEventJSON.decode(
      try Data(contentsOf: fixtures.appending(path: "aidoku-validation-3-build-events.jsonl")))
    try #require(log.damage.isEmpty)
    let abandon = log.events.firstIndex {
      guard case .transition(let transition) = $0 else { return false }
      return transition.to == .abandoned
    }
    let cut = try #require(abandon)
    return Array(log.events[..<cut])
  }

  static func stage(after count: Int, of events: [BuildEvent]) -> CutoffTaskStage? {
    BuildEventLog(events: Array(events.prefix(count)), damage: []).mergeStage(task: task)
  }

  @Test(
    "the task whose fix merged and whose GREEN merge gate was recorded just before the cutoff reads landed and finishes, though its merge gate no longer fits the box — catches the cutoff abandoning a merged, gated task"
  )
  func landedTaskFinishes() throws {
    let events = try Self.eventsBeforeCutoff()
    let record = try CutoffRecord.decode(
      Data(contentsOf: Self.fixtures.appending(path: "aidoku-validation-3-cutoff.json")))
    let log = BuildEventLog(events: events, damage: [])

    #expect(log.mergeStage(task: Self.task) == .landed)
    let decisions = CutoffRule.decide(
      tasks: [CutoffTask(id: Self.task, stage: .landed)], timeBox: record.timeBox, now: record.at)
    #expect(decisions.map(\.action) == [.finishMerge])
    #expect(record.decisions.map(\.action) == [.abandon])
  }

  @Test(
    "the setting task reads merged after each merge until its GREEN gate, and not merged once its RED merge was undone — catches a gate from an undone merge counting for the next, or an undo left on main"
  )
  func stageFollowsMergesAndUndo() throws {
    let events = try Self.eventsBeforeCutoff()
    func index(_ match: (BuildEvent) -> Bool) throws -> Int {
      let found = events.firstIndex(where: match)
      return try #require(found)
    }
    let firstMerge = try index {
      if case .merge(let merge) = $0 { return merge.task == Self.task }
      return false
    }
    let undo = try index {
      if case .undo(let undo) = $0 { return undo.task == Self.task }
      return false
    }
    let gate = try index {
      if case .gate(let gate) = $0, case .merge(let task) = gate.stage { return task == Self.task }
      return false
    }

    #expect(Self.stage(after: firstMerge, of: events) == nil)
    #expect(Self.stage(after: firstMerge + 1, of: events) == .merged)
    #expect(Self.stage(after: undo + 1, of: events) == nil)
    #expect(Self.stage(after: gate, of: events) == .merged)
    #expect(Self.stage(after: gate + 1, of: events) == .landed)
  }
}

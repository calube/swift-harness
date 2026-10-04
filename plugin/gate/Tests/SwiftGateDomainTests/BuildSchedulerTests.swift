import Foundation
import SwiftGateDomain
import Testing

extension BuildScheduler {
  /// The scheduling tests that predate required tasks read a ledger with none.
  fileprivate static func next(
    ledger: Ledger, running: Set<String>, preset: BuildPreset, startedAt: Date, now: Date
  ) -> Result {
    next(
      ledger: ledger, running: running, preset: preset, startedAt: startedAt, now: now,
      required: .empty)
  }
}

@Suite("Build scheduler (design spec §8.1, §8.5)")
struct BuildSchedulerTests {
  static func task(
    id: String, deps: [String] = [], writeSet: [String]? = nil, estLines: Int = 100,
    status: TaskStatus = .pending, model: TaskModel? = .sonnet
  ) -> LedgerTask {
    LedgerTask(
      id: id, deps: deps, writeSet: writeSet ?? ["\(id)/"], gate: .push, tests: ["test-\(id)"],
      covers: ["test-\(id)"], estLines: estLines, status: status, worktree: "../\(id)", model: model
    )
  }

  static func preset(
    maxParallel: Int = 3, workerModel: BuildPreset.WorkerModel = .sonnet, timeBudgetMin: Int = 0,
    stopStartsBeforeMin: Int = 0
  ) -> BuildPreset {
    BuildPreset(
      designTier: .standard, maxParallel: maxParallel, review: .full, taskGate: .ledger,
      mergeGate: .push, workerModel: workerModel, timeBudgetMin: timeBudgetMin,
      stopStartsBeforeMin: stopStartsBeforeMin, onDesignConflict: .amend)
  }

  static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

  static func ledger(_ tasks: [LedgerTask]) -> Ledger {
    Ledger(schemaVersion: 1, resume: "resume", maxParallel: 3, tasks: tasks, waves: [])
  }

  // MARK: - Readiness

  @Test(
    "a task with 1 unmerged dep never starts — catches a dependency check that ignores status"
  )
  func unmergedDependencyNeverStarts() {
    let dep = Self.task(id: "dep-unmerged", status: .pending)
    let blocked = Self.task(id: "downstream", deps: ["dep-unmerged"])
    let ledger = Self.ledger([dep, blocked])

    let result = BuildScheduler.next(
      ledger: ledger, running: [], preset: Self.preset(), startedAt: Self.epoch, now: Self.epoch)

    #expect(!result.toStart.contains("downstream"))
    #expect(result.toStart.contains("dep-unmerged"))
  }

  @Test(
    "blocked and abandoned deps never unlock dependents — catches a status check narrower than every non-done state"
  )
  func blockedAndAbandonedDepsNeverUnlock() {
    let blockedDep = Self.task(id: "dep-blocked", status: .blocked)
    let downstreamOfBlocked = Self.task(id: "downstream-of-blocked", deps: ["dep-blocked"])
    let abandonedDep = Self.task(id: "dep-abandoned", status: .abandoned)
    let downstreamOfAbandoned = Self.task(id: "downstream-of-abandoned", deps: ["dep-abandoned"])
    let ledger = Self.ledger([
      blockedDep, downstreamOfBlocked, abandonedDep, downstreamOfAbandoned,
    ])

    let result = BuildScheduler.next(
      ledger: ledger, running: [], preset: Self.preset(maxParallel: 10), startedAt: Self.epoch,
      now: Self.epoch)

    #expect(!result.toStart.contains("downstream-of-blocked"))
    #expect(!result.toStart.contains("downstream-of-abandoned"))
  }

  // MARK: - Write-set overlap

  @Test(
    "2 ready tasks with overlapping write sets start in different calls — catches a same-call double start on 1 file"
  )
  func overlappingWriteSetsStartInDifferentCalls() {
    let taskA = Self.task(id: "task-a", writeSet: ["shared/"])
    let taskB = Self.task(id: "task-b", writeSet: ["shared/file.swift"])
    let firstCallLedger = Self.ledger([taskA, taskB])

    let firstResult = BuildScheduler.next(
      ledger: firstCallLedger, running: [], preset: Self.preset(maxParallel: 2),
      startedAt: Self.epoch, now: Self.epoch)
    #expect(firstResult.toStart == ["task-a"])

    let secondCallLedger = Self.ledger([
      Self.task(id: "task-a", writeSet: ["shared/"], status: .done), taskB,
    ])
    let secondResult = BuildScheduler.next(
      ledger: secondCallLedger, running: [], preset: Self.preset(maxParallel: 2),
      startedAt: Self.epoch, now: Self.epoch)
    #expect(secondResult.toStart == ["task-b"])
  }

  // MARK: - Ordering

  @Test(
    "critical-path task starts first when slots are short — catches ordering by a task's own estLines instead of its remaining chain"
  )
  func criticalPathTaskStartsFirstWhenSlotsAreShort() {
    let unlocksMany = Self.task(id: "unlocks-many", estLines: 50)
    let dependent = Self.task(
      id: "dependent-of-unlocks-many", deps: ["unlocks-many"], estLines: 200)
    let solo = Self.task(id: "solo", estLines: 200)
    let ledger = Self.ledger([unlocksMany, dependent, solo])

    let result = BuildScheduler.next(
      ledger: ledger, running: [], preset: Self.preset(maxParallel: 1), startedAt: Self.epoch,
      now: Self.epoch)

    #expect(result.toStart == ["unlocks-many"])
  }

  // MARK: - Model refusal

  @Test(
    "a ready task with no model is refused under a tagged preset but may start under a forced one — catches a scheduler that starts an untagged task with no worker model"
  )
  func missingModelRefusedOnlyWhenPresetIsTagged() {
    let noModel = Self.task(id: "task-no-model", model: nil)
    let alsoNoModel = Self.task(id: "another-no-model", model: nil)
    let ledger = Self.ledger([noModel, alsoNoModel])

    let taggedResult = BuildScheduler.next(
      ledger: ledger, running: [], preset: Self.preset(workerModel: .tagged),
      startedAt: Self.epoch, now: Self.epoch)
    #expect(taggedResult.toStart.isEmpty)
    #expect(
      taggedResult.refused == [
        BuildScheduler.Refusal(taskID: "another-no-model", reason: .missingModel),
        BuildScheduler.Refusal(taskID: "task-no-model", reason: .missingModel),
      ])

    let forcedResult = BuildScheduler.next(
      ledger: ledger, running: [], preset: Self.preset(maxParallel: 2, workerModel: .sonnet),
      startedAt: Self.epoch, now: Self.epoch)
    #expect(forcedResult.toStart.sorted() == ["another-no-model", "task-no-model"])
    #expect(forcedResult.refused.isEmpty)
  }

  // MARK: - Budget phase boundaries

  @Test(
    "phase flips to no-new-starts at exactly budget minus stop and to cutoff at exactly budget — catches an off-by-one-minute boundary"
  )
  func phaseFlipsAtExactBoundaries() {
    let ledger = Self.ledger([Self.task(id: "solo")])
    let preset = Self.preset(timeBudgetMin: 30, stopStartsBeforeMin: 5)

    func phase(afterSeconds seconds: TimeInterval) -> BudgetPhase {
      BuildScheduler.next(
        ledger: ledger, running: [], preset: preset, startedAt: Self.epoch,
        now: Self.epoch.addingTimeInterval(seconds)
      ).phase
    }

    #expect(phase(afterSeconds: 25 * 60 - 1) == .normal)
    #expect(phase(afterSeconds: 25 * 60) == .noNewStarts)
    #expect(phase(afterSeconds: 30 * 60 - 1) == .noNewStarts)
    #expect(phase(afterSeconds: 30 * 60) == .cutoff)
  }

  @Test(
    "no-new-starts and cutoff start nothing even with a ready task — catches a phase check that only gates the message, not the starts"
  )
  func noNewStartsAndCutoffStartNothing() {
    let ledger = Self.ledger([Self.task(id: "solo")])
    let preset = Self.preset(timeBudgetMin: 30, stopStartsBeforeMin: 5)

    let noNewStarts = BuildScheduler.next(
      ledger: ledger, running: [], preset: preset, startedAt: Self.epoch,
      now: Self.epoch.addingTimeInterval(25 * 60))
    #expect(noNewStarts.toStart.isEmpty)

    let cutoff = BuildScheduler.next(
      ledger: ledger, running: [], preset: preset, startedAt: Self.epoch,
      now: Self.epoch.addingTimeInterval(30 * 60))
    #expect(cutoff.toStart.isEmpty)
  }

  // MARK: - Tasks the app target needs

  static let packages = ["Packages/Feed", "Packages/Posts"]

  @Test(
    "a task writing a .swift file outside every package is required, and so is each not-done task it depends on — catches the app target read as package code, or a required task left waiting on an optional dependency"
  )
  func requiredTasksFollowTheAppTarget() {
    let ledger = Self.ledger([
      Self.task(
        id: "done-core", writeSet: ["Packages/Feed/Sources/Feed/Feed.swift"], status: .done),
      Self.task(
        id: "posts-core", deps: ["done-core"],
        writeSet: ["Packages/Posts/Sources/Posts/Posts.swift"]),
      Self.task(
        id: "app-views", deps: ["posts-core"],
        writeSet: ["Packages/Posts/Sources/PostsUI/List.swift", "App/AppView.swift"]),
      Self.task(id: "feed-only", writeSet: ["Packages/Feed/Sources/Feed/More.swift"]),
      Self.task(id: "docs-only", writeSet: ["docs/notes.md", "App/"]),
      Self.task(id: "prefix-lookalike", writeSet: ["Packages/FeedExtras/Extra.swift"]),
    ])

    let required = BuildScheduler.RequiredTasks(ledger: ledger, packageDirectories: Self.packages)

    #expect(
      required.tasks == [
        .init(taskID: "app-views", appPath: "App/AppView.swift"),
        .init(taskID: "posts-core", appPath: "App/AppView.swift"),
        .init(taskID: "prefix-lookalike", appPath: "Packages/FeedExtras/Extra.swift"),
      ])
  }

  @Test(
    "past the no-new-starts point a required task still starts and an optional one doesn't, and at cutoff neither does — catches a RED final gate from a skipped view task"
  )
  func requiredTaskStartsPastNoNewStarts() {
    let ledger = Self.ledger([
      Self.task(id: "app-views", writeSet: ["App/AppView.swift"], estLines: 10),
      Self.task(id: "optional-core", writeSet: ["Packages/Feed/Sources/Feed/Feed.swift"]),
    ])
    let required = BuildScheduler.RequiredTasks(ledger: ledger, packageDirectories: Self.packages)
    let preset = Self.preset(timeBudgetMin: 30, stopStartsBeforeMin: 5)

    let noNewStarts = BuildScheduler.next(
      ledger: ledger, running: [], preset: preset, startedAt: Self.epoch,
      now: Self.epoch.addingTimeInterval(26 * 60), required: required)

    #expect(noNewStarts.phase == .noNewStarts)
    #expect(noNewStarts.toStart == ["app-views"])

    let cutoff = BuildScheduler.next(
      ledger: ledger, running: [], preset: preset, startedAt: Self.epoch,
      now: Self.epoch.addingTimeInterval(30 * 60), required: required)
    #expect(cutoff.phase == .cutoff)
    #expect(cutoff.toStart.isEmpty)
  }

  @Test(
    "past the no-new-starts point required tasks still fill only free slots and skip write-set overlaps — catches the exemption also bypassing capacity"
  )
  func requiredTasksRespectSlotsAndOverlap() {
    let ledger = Self.ledger([
      Self.task(id: "running-app", writeSet: ["App/Root.swift"], status: .inProgress),
      Self.task(id: "app-overlap", writeSet: ["App/Root.swift"]),
      Self.task(id: "app-a", writeSet: ["App/A.swift"]),
      Self.task(id: "app-b", writeSet: ["App/B.swift"]),
    ])
    let required = BuildScheduler.RequiredTasks(ledger: ledger, packageDirectories: Self.packages)

    let result = BuildScheduler.next(
      ledger: ledger, running: ["running-app"],
      preset: Self.preset(maxParallel: 2, timeBudgetMin: 30, stopStartsBeforeMin: 5),
      startedAt: Self.epoch, now: Self.epoch.addingTimeInterval(26 * 60), required: required)

    #expect(result.toStart == ["app-a"])
  }

  // MARK: - Determinism

  @Test(
    "output is identical over permuted task order — catches a result that depends on array order instead of ids"
  )
  func outputIdenticalOverPermutedTaskOrder() {
    let tasks = [
      Self.task(id: "dep-blocked", status: .blocked),
      Self.task(id: "downstream-of-blocked", deps: ["dep-blocked"]),
      Self.task(id: "unlocks-many", estLines: 50),
      Self.task(id: "dependent-of-unlocks-many", deps: ["unlocks-many"], estLines: 200),
      Self.task(id: "solo", estLines: 200),
      Self.task(id: "task-a", writeSet: ["shared/"]),
      Self.task(id: "task-b", writeSet: ["shared/file.swift"]),
      Self.task(id: "task-no-model", model: nil),
      Self.task(id: "another-no-model", model: nil),
    ]
    let preset = Self.preset(maxParallel: 3, workerModel: .tagged)

    let baseline = BuildScheduler.next(
      ledger: Self.ledger(tasks), running: [], preset: preset, startedAt: Self.epoch,
      now: Self.epoch)

    let permutations: [[LedgerTask]] = [
      tasks.reversed(),
      [
        tasks[3], tasks[0], tasks[7], tasks[1], tasks[5], tasks[2], tasks[6], tasks[4], tasks[8],
      ],
      tasks.sorted { $0.id > $1.id },
    ]
    for permuted in permutations {
      let result = BuildScheduler.next(
        ledger: Self.ledger(permuted), running: [], preset: preset, startedAt: Self.epoch,
        now: Self.epoch)
      #expect(result == baseline)
    }
  }

  @Test(
    "a brownfield preset that leaves the model to the task refuses an alias-tagged task as unpinned-model, where an owned one starts it — catches a brownfield worker on a moving alias"
  )
  func brownfieldRefusesAliasTag() {
    let ledger = Self.ledger([Self.task(id: "a", model: .sonnet)])
    let brownfield = BuildPreset(
      designTier: .none, maxParallel: 3, review: .classified, taskGate: .tier(.slice),
      mergeGate: .merge, workerModel: .tagged, timeBudgetMin: 0, stopStartsBeforeMin: 0,
      onDesignConflict: .block, taskProof: .prove, stallMin: 2)

    let refused = BuildScheduler.next(
      ledger: ledger, running: [], preset: brownfield, startedAt: Self.epoch, now: Self.epoch)
    let started = BuildScheduler.next(
      ledger: ledger, running: [], preset: Self.preset(workerModel: .tagged),
      startedAt: Self.epoch, now: Self.epoch)

    #expect(refused.toStart.isEmpty)
    #expect(refused.refused == [.init(taskID: "a", reason: .unpinnedModel)])
    #expect(started.toStart == ["a"])
  }
}

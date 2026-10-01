import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("events summary: missed REDs")
struct MissDetectionTests {
  typealias Wrong = WrongGatesSectionTests

  static let otherTree = "0123456789abcdef0123456789abcdef01234567"
  static let fastTiers = [GateRunTier(tier: .t0, verdict: .green, milliseconds: 10)]
  static let writeSet = ["Sources/Feature/", "Tests/FeatureTests/FeatureTests.swift"]
  static let at = Date(timeIntervalSince1970: 1_790_000_000)

  static func taskReturn(_ task: String, _ verdict: Verdict, runID: String) -> TaskReturn {
    TaskReturn(
      task: task, outcome: verdict == .green ? .readyToMerge : .gateRed, commits: ["abc1234"],
      gate: TaskReturn.Gate(tier: .push, verdict: verdict, runID: runID), review: nil,
      testsAdded: [], notes: "", designConflict: nil)
  }

  static func merge(_ task: String) -> BuildEvent {
    .merge(BuildEvent.Merge(task: task, preCommit: "aaa1111", postCommit: "bbb2222", at: at))
  }

  static func mainGate(_ runID: String, _ verdict: Verdict, task: String? = nil) -> BuildEvent {
    .gate(
      BuildEvent.Gate(
        stage: task.map { .merge(task: $0) } ?? .final, tier: .push, verdict: verdict,
        runID: runID, at: at))
  }

  static func builds(
    returns: [TaskReturn], events: [BuildEvent], writeSets: [String: [String]]? = nil
  ) -> BuildJoin {
    BuildJoin(
      source: "swift-harness/plans",
      runs: [
        BuildJoin.Run(
          plan: "telemetry", runID: "20261001T000000Z-build001",
          writeSets: writeSets
            ?? Dictionary(uniqueKeysWithValues: returns.map { ($0.task, writeSet) }),
          returns: Dictionary(uniqueKeysWithValues: returns.map { ($0.task, $0) }), events: events)
      ],
      damage: [])
  }

  @Test(
    "a GREEN task gate, then a RED on main naming a file in the task's write set, is 1 miss naming the task, the rule and both run ids; a RED naming only files outside it is none — catches a miss on any later RED"
  )
  func redInsideTheWriteSetIsAMiss() {
    let events = [
      Wrong.run("task-green", .green, treeHash: Self.otherTree, at: 0),
      Wrong.run(
        "main-red", .red, rules: ["t1.failed": 1], paths: ["Sources/Feature/Feature.swift"],
        at: 10),
      Wrong.run(
        "main-red-outside", .red, rules: ["arch.layering": 1], paths: ["Sources/Other/Other.swift"],
        at: 20),
    ]
    let builds = Self.builds(
      returns: [Self.taskReturn("feature", .green, runID: "task-green")],
      events: [
        Self.merge("feature"), Self.mainGate("main-red", .red, task: "feature"),
        Self.mainGate("main-red-outside", .red),
      ])

    let found = MissFindings(events: events, builds: builds)

    #expect(
      found.taskMisses == [
        TaskMiss(
          plan: "telemetry", buildRunID: "20261001T000000Z-build001", task: "feature",
          greenRunID: "task-green", redRunID: "main-red", rules: ["t1.failed"],
          paths: ["Sources/Feature/Feature.swift"])
      ])
    #expect(found.comparedTasks == 1)
    #expect(found.uncomparedTasks.isEmpty)
  }

  @Test(
    "a task whose gate was RED is never a miss, even when a later RED on main names its write set — catches a RED task gate counted as missing what it found"
  )
  func redTaskGateIsNeverAMiss() {
    let events = [
      Wrong.run("task-red", .red, rules: ["t1.failed": 1], at: 0),
      Wrong.run("task-green", .green, treeHash: Self.otherTree, at: 5),
      Wrong.run(
        "main-red", .red, rules: ["t1.failed": 1], paths: ["Sources/Feature/Feature.swift"],
        at: 10),
    ]
    let builds = Self.builds(
      returns: [
        Self.taskReturn("red-gate", .red, runID: "task-red"),
        Self.taskReturn("green-gate", .green, runID: "task-green"),
      ],
      events: [Self.merge("red-gate"), Self.merge("green-gate"), Self.mainGate("main-red", .red)])

    let found = MissFindings(events: events, builds: builds)

    #expect(found.taskMisses.map(\.task) == ["green-gate"])
    #expect(found.comparedTasks == 1)
  }

  @Test(
    "a RED on main before the task merged, or after its merge was undone, isn't the task's miss — catches a RED blamed on a task that wasn't on main"
  )
  func redOffMainIsNotTheTasksMiss() {
    let paths = ["Sources/Feature/Feature.swift"]
    let events = [
      Wrong.run("task-green", .green, treeHash: Self.otherTree, at: 0),
      Wrong.run("before", .red, rules: ["t1.failed": 1], paths: paths, at: 10),
      Wrong.run("after-undo", .red, rules: ["t1.failed": 1], paths: paths, at: 20),
    ]
    let builds = Self.builds(
      returns: [Self.taskReturn("feature", .green, runID: "task-green")],
      events: [
        Self.mainGate("before", .red), Self.merge("feature"),
        .undo(
          BuildEvent.Undo(task: "feature", fromCommit: "bbb2222", toCommit: "aaa1111", at: Self.at)),
        Self.mainGate("after-undo", .red),
      ])

    let found = MissFindings(events: events, builds: builds)

    #expect(found.taskMisses.isEmpty)
    #expect(found.comparedTasks == 1)
  }

  @Test(
    "a GREEN task gate on a dirty tree, or one with no gate.run event, isn't compared and is listed with its reason — catches a dirty GREEN vouching for a tree"
  )
  func dirtyOrUnseenTaskGateIsUncompared() {
    let paths = ["Sources/Feature/Feature.swift"]
    let events = [
      Wrong.run("dirty-green", .green, treeHash: nil, dirty: true, at: 0),
      Wrong.run("main-red", .red, rules: ["t1.failed": 1], paths: paths, at: 10),
    ]
    let builds = Self.builds(
      returns: [
        Self.taskReturn("dirty", .green, runID: "dirty-green"),
        Self.taskReturn("unseen", .green, runID: "never-recorded"),
      ],
      events: [Self.merge("dirty"), Self.merge("unseen"), Self.mainGate("main-red", .red)])

    let found = MissFindings(events: events, builds: builds)

    #expect(found.taskMisses.isEmpty)
    #expect(found.comparedTasks == 0)
    #expect(
      found.uncomparedTasks.map(\.reason) == [.dirtyGateRun, .noGateRunEvent])
  }

  @Test(
    "a clean GREEN then a clean RED on the same tree is 1 tree miss naming the rules the GREEN didn't report; on another tree, or with either run dirty, it isn't — catches a code change or a dirty tree read as a miss"
  )
  func sameCleanTreeRedAfterGreenIsATreeMiss() {
    let red = ["t1.failed": 2, "coverage.summary": 1]
    let events = [
      Wrong.run(
        "fast", .green, command: "check fast", tiers: Self.fastTiers,
        rules: ["coverage.summary": 1], at: 0),
      Wrong.run("push", .red, rules: red, at: 10),
      Wrong.run("other-green", .green, treeHash: Self.otherTree, at: 20),
      Wrong.run("dirty-green", .green, treeHash: nil, dirty: true, at: 30),
      Wrong.run("dirty-red", .red, treeHash: nil, dirty: true, rules: red, at: 40),
      Wrong.run("unknown-dirty", .red, treeHash: Self.otherTree, dirty: nil, rules: red, at: 50),
    ]

    let found = MissFindings(events: events, builds: nil)

    #expect(
      found.treeMisses == [
        TreeMiss(
          treeHash: Wrong.tree, greenCommand: "check fast", greenTiers: [.t0], greenRunID: "fast",
          redCommand: "check push", redTiers: [.t0, .t1], redRunID: "push", rules: ["t1.failed"])
      ])
    #expect(found.reGatedGreens == 1)
  }

  @Test(
    "2 GREENs then a RED on 1 clean tree are 2 missed GREENs of 2 re-gated, and a GREEN followed only by a GREEN is re-gated but not missed — catches the rate's n counting runs instead of GREENs"
  )
  func everyOpenGreenIsMissedOnce() {
    let events = [
      Wrong.run("g1", .green, at: 0),
      Wrong.run("g2", .green, at: 10),
      Wrong.run("r1", .red, rules: ["t1.failed": 1], at: 20),
      Wrong.run("r2", .red, rules: ["t1.failed": 1], at: 30),
      Wrong.run("o1", .green, treeHash: Self.otherTree, at: 40),
      Wrong.run("o2", .green, treeHash: Self.otherTree, at: 50),
    ]

    let found = MissFindings(events: events, builds: nil)

    #expect(found.treeMisses.map(\.greenRunID) == ["g1", "g2"])
    #expect(found.treeMisses.map(\.redRunID) == ["r1", "r1"])
    #expect(found.reGatedGreens == 3)
  }

  @Test(
    "the section reports both kinds of miss with n beside each count and rate, names the task, rule and both run ids, and lists build state damage — catches a rate printed without its n or damage dropped"
  )
  func sectionPrintsMissesWithN() throws {
    let events = [
      Wrong.run("task-green", .green, treeHash: Self.otherTree, at: 0),
      Wrong.run(
        "main-red", .red, rules: ["t1.failed": 1], paths: ["Sources/Feature/Feature.swift"],
        at: 10),
    ]
    let joined = Self.builds(
      returns: [Self.taskReturn("feature", .green, runID: "task-green")],
      events: [Self.merge("feature"), Self.mainGate("main-red", .red, task: "feature")])
    let builds = BuildJoin(
      source: joined.source, runs: joined.runs,
      damage: [
        BuildJoinDamage(path: "swift-harness/plans/other/ledger.json", reason: "missing ledger")
      ])

    let report = try #require(
      WrongGatesSection(builds: builds).summarize(GateTimeSectionTests.input(events)))

    let misses = try #require(Wrong.metric(report, "task-misses"))
    #expect(misses.value == 1)
    #expect(misses.n == 1)
    #expect(Wrong.metric(report, "task-miss-rate")?.value == 1)
    #expect(Wrong.metric(report, "task-miss-rate")?.n == 1)
    #expect(Wrong.metric(report, "tree-misses")?.n == 0)
    #expect(Wrong.metric(report, "tree-miss-rate") == nil)
    #expect(Wrong.metric(report, "build-join-damage")?.value == 1)
    #expect(
      report.lines.contains {
        $0.contains("feature") && $0.contains("t1.failed") && $0.contains("task-green")
          && $0.contains("main-red")
      })
    #expect(report.lines.contains { $0.contains("missing ledger") && $0.contains("other") })
    #expect(report.lines.contains { $0.contains("(n=1)") && $0.contains("task misses") })
  }

  @Test(
    "with no build state read, the section says task misses weren't joined instead of printing 0 — catches an unread join reported as no misses"
  )
  func unreadBuildStateIsSaid() throws {
    let report = try #require(
      WrongGatesSection().summarize(
        GateTimeSectionTests.input([Wrong.run("g", .green, at: 0)])))

    #expect(report.lines.contains { $0.contains("task misses") && $0.contains("not read") })
    #expect(Wrong.metric(report, "task-misses") == nil)
  }

  @Test(
    "on this repo's recorded runs, a task cited the clean GREEN push run and main's RED push run named the design doc: the docs task is 1 miss on the prose rules, and the events task whose files the GREEN already named isn't — catches a finding the task gate already reported counted as missed"
  )
  func realGateRunsJoinToTasks() throws {
    let green = try HarnessEventJSON.decode(Fixture.data("Events/test-run-gate.jsonl")).events
    let recorded = try HarnessEventJSON.decode(Fixture.data("Events/gate.jsonl")).events
    let redRunID = "20261001T033943Z-bd07526c"
    let greenRunID = "20261001T044910Z-f9efb34a"
    #expect(recorded.contains { $0.runID == redRunID })
    #expect(green.map(\.runID) == [greenRunID])
    let builds = Self.builds(
      returns: [
        Self.taskReturn("docs-task", .green, runID: greenRunID),
        Self.taskReturn("events-task", .green, runID: greenRunID),
      ],
      events: [Self.merge("docs-task"), Self.merge("events-task"), Self.mainGate(redRunID, .red)],
      writeSets: [
        "docs-task": ["docs/designs/"],
        "events-task": ["plugin/gate/Sources/SwiftGateAdapters/Events/"],
      ])

    let found = MissFindings(events: recorded + green, builds: builds)

    #expect(
      found.taskMisses == [
        TaskMiss(
          plan: "telemetry", buildRunID: "20261001T000000Z-build001", task: "docs-task",
          greenRunID: greenRunID, redRunID: redRunID,
          rules: ["prose.passive-voice", "prose.sentence-length"],
          paths: ["docs/designs/2026-09-30-harness-telemetry-design.md"])
      ])
    #expect(found.comparedTasks == 2)
    #expect(found.treeMisses.isEmpty)
    #expect(found.reGatedGreens == 0)
  }
}

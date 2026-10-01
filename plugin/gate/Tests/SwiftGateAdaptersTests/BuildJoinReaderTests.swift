import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import Testing

@Suite("build join reader: task returns, ledger write sets and build events")
struct BuildJoinReaderTests {
  static let runID = "20261001T000000Z-build001"
  static let at = Date(timeIntervalSince1970: 1_790_000_000)

  /// A temp repo's plan state, written through the formats' own encoders.
  struct PlanState {
    let repo: TemporaryGitRepository
    let common: URL

    static func make() async throws -> PlanState {
      let repo = try await TemporaryGitRepository()
      let common = URL(
        filePath: try await repo.adapter.commonDirectory(), directoryHint: .isDirectory)
      return PlanState(repo: repo, common: common)
    }

    func plan(_ name: String) -> URL {
      common.appending(
        path: "\(BuildJoinReader.plansDirectory)/\(name)", directoryHint: .isDirectory)
    }

    func write(_ data: Data, to url: URL) throws {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url)
    }

    func writeLedger(plan name: String, writeSets: [String: [String]]) throws {
      let tasks = writeSets.keys.sorted().map {
        LedgerTask(
          id: $0, deps: [], writeSet: writeSets[$0] ?? [], gate: .push, tests: [], covers: [],
          estLines: 10, status: .done, worktree: "../\($0)")
      }
      try write(
        LedgerJSON.encode(
          Ledger(
            schemaVersion: 1, resume: "", maxParallel: 2, tasks: tasks, waves: [tasks.map(\.id)])),
        to: plan(name).appending(path: "ledger.json"))
    }

    func writeRun(
      plan name: String, runID: String = BuildJoinReaderTests.runID, returns: [TaskReturn],
      events: [BuildEvent]
    ) throws {
      let run = plan(name).appending(path: "build/\(runID)", directoryHint: .isDirectory)
      for taskReturn in returns {
        try write(
          TaskReturnJSON.encode(taskReturn),
          to: run.appending(path: "returns/\(taskReturn.task).json"))
      }
      try write(
        events.reduce(into: Data()) { $0.append(try BuildEventJSON.encodeLine($1)) },
        to: run.appending(path: "events.jsonl"))
    }

    func remove() { repo.remove() }
  }

  static func taskReturn(_ task: String, runID: String) -> TaskReturn {
    TaskReturn(
      task: task, outcome: .readyToMerge, commits: ["abc1234"],
      gate: TaskReturn.Gate(tier: .push, verdict: .green, runID: runID), review: nil,
      testsAdded: [], notes: "", designConflict: nil)
  }

  static let events: [BuildEvent] = [
    .merge(BuildEvent.Merge(task: "feature", preCommit: "aaa1111", postCommit: "bbb2222", at: at)),
    .gate(
      BuildEvent.Gate(
        stage: .merge(task: "feature"), tier: .push, verdict: .red,
        runID: "20261001T000100Z-main0001", at: at)),
  ]

  @Test(
    "a build run's returns, its plan's write sets and its events are read from the git common dir — catches a join that reads the worktree instead of shared plan state"
  )
  func readsTheRunFromTheCommonDirectory() async throws {
    let state = try await PlanState.make()
    defer { state.remove() }
    try state.writeLedger(plan: "telemetry", writeSets: ["feature": ["Sources/Feature/"]])
    let taskReturn = Self.taskReturn("feature", runID: "20261001T000000Z-task0001")
    try state.writeRun(plan: "telemetry", returns: [taskReturn], events: Self.events)

    let join = BuildJoinReader(commonDirectory: state.common).read(buildRunID: nil)

    #expect(join.damage == [])
    #expect(
      join.runs == [
        BuildJoin.Run(
          plan: "telemetry", runID: Self.runID, writeSets: ["feature": ["Sources/Feature/"]],
          returns: ["feature": taskReturn], events: Self.events)
      ])
  }

  @Test(
    "a build run whose plan has no ledger is listed as damage naming the ledger, not read as a run with no tasks — catches a missing ledger reported as an empty result"
  )
  func missingLedgerIsDamage() async throws {
    let state = try await PlanState.make()
    defer { state.remove() }
    try state.writeRun(
      plan: "telemetry", returns: [Self.taskReturn("feature", runID: "20261001T000000Z-task0001")],
      events: Self.events)

    let join = BuildJoinReader(commonDirectory: state.common).read(buildRunID: nil)

    #expect(
      join.damage.map(\.path) == ["\(BuildJoinReader.plansDirectory)/telemetry/ledger.json"])
    #expect(join.damage.first?.reason.contains("missing") == true)
    #expect(join.runs.map(\.writeSets) == [[:]])
    #expect(join.runs.map(\.returns.count) == [1])
  }

  @Test(
    "an undecodable return or build log line is listed as damage by file, and the rest of the run is still read — catches 1 bad file dropping the run or being dropped silently"
  )
  func undecodableFilesAreDamage() async throws {
    let state = try await PlanState.make()
    defer { state.remove() }
    try state.writeLedger(plan: "telemetry", writeSets: ["feature": ["Sources/Feature/"]])
    try state.writeRun(
      plan: "telemetry", returns: [Self.taskReturn("feature", runID: "20261001T000000Z-task0001")],
      events: Self.events)
    let run = state.plan("telemetry").appending(path: "build/\(Self.runID)")
    try Data("{\"task\":\"broken\"}".utf8).write(to: run.appending(path: "returns/broken.json"))
    let log = run.appending(path: "events.jsonl")
    try (Data(contentsOf: log) + Data("{\"kind\":\"nope\"}\n".utf8)).write(to: log)

    let join = BuildJoinReader(commonDirectory: state.common).read(buildRunID: nil)

    let prefix = "\(BuildJoinReader.plansDirectory)/telemetry/build/\(Self.runID)"
    #expect(
      join.damage.map(\.path).sorted() == [
        "\(prefix)/events.jsonl:3", "\(prefix)/returns/broken.json",
      ])
    #expect(join.runs.first?.returns.keys.sorted() == ["feature"])
    #expect(join.runs.first?.events == Self.events)
  }

  @Test(
    "a build run id selects only that run, and an id no plan holds is damage — catches every run joined under --build-run or an unknown id read as no misses"
  )
  func buildRunIDSelectsOneRun() async throws {
    let state = try await PlanState.make()
    defer { state.remove() }
    try state.writeLedger(plan: "telemetry", writeSets: ["feature": ["Sources/Feature/"]])
    try state.writeRun(plan: "telemetry", returns: [], events: Self.events)
    try state.writeRun(
      plan: "telemetry", runID: "20261002T000000Z-build002", returns: [], events: [])

    let reader = BuildJoinReader(commonDirectory: state.common)
    let one = reader.read(buildRunID: "20261002T000000Z-build002")
    let unknown = reader.read(buildRunID: "20261003T000000Z-build003")

    #expect(one.runs.map(\.runID) == ["20261002T000000Z-build002"])
    #expect(one.damage == [])
    #expect(unknown.runs.isEmpty)
    #expect(unknown.damage.map(\.reason).contains { $0.contains("20261003T000000Z-build003") })
  }
}

import Darwin
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

/// A process table of scripted pids: a pid runs while it has a start time, and terminating it
/// ends it.
private final class ScriptedProcesses: GateProcesses {
  private let table: Mutex<[Int32: Double]>
  private let ended = Mutex<[Int32]>([])

  init(_ table: [Int32: Double]) { self.table = Mutex(table) }

  var terminated: [Int32] { ended.withLock { $0 } }

  func startTime(of pid: Int32) -> Double? { table.withLock { $0[pid] } }

  func terminate(_ pid: Int32) async {
    ended.withLock { $0.append(pid) }
    _ = table.withLock { $0.removeValue(forKey: pid) }
  }
}

@Suite("running gates")
struct RunningGatesTests {
  private static let now = Date(timeIntervalSince1970: 1_790_000_000)

  @Test(
    "a registered gate is listed while its process runs and unregistering drops it — catches a cutoff blind to the gates in flight"
  )
  func registeredGateIsListed() throws {
    let directory = try TestTemporaryDirectory.make("gates")
    defer { TestTemporaryDirectory.remove(directory) }
    let processes = ScriptedProcesses([4242: 100])
    let registry = RunningGateRegistry(directory: directory, processes: processes)

    let record = try #require(
      registry.register(pid: 4242, toplevel: "/repo-plan-task", tier: .merge, now: Self.now))

    #expect(
      registry.running()
        == [
          RunningGate(
            pid: 4242, processStart: 100, toplevel: "/repo-plan-task", tier: "merge",
            startedAt: Self.now)
        ])
    registry.unregister(record)
    #expect(registry.running().isEmpty)
  }

  @Test(
    "a record whose process ended, or whose pid now belongs to a process that started later, is dropped and never signalled — catches a cutoff killing an unrelated process that reused a gate's pid"
  )
  func staleRecordsAreDropped() async throws {
    let directory = try TestTemporaryDirectory.make("gates")
    defer { TestTemporaryDirectory.remove(directory) }
    let registering = ScriptedProcesses([10: 100, 11: 100])
    let registry = RunningGateRegistry(directory: directory, processes: registering)
    _ = registry.register(pid: 10, toplevel: "/repo-task", tier: .slice, now: Self.now)
    _ = registry.register(pid: 11, toplevel: "/repo-task", tier: .slice, now: Self.now)
    #expect((try FileManager.default.contentsOfDirectory(atPath: directory.path)).count == 2)

    let later = ScriptedProcesses([11: 900])
    let reading = RunningGateRegistry(directory: directory, processes: later)

    #expect(reading.running().isEmpty)
    #expect(await reading.stop(in: ["/repo-task"]).isEmpty)
    #expect(later.terminated.isEmpty)
    #expect((try FileManager.default.contentsOfDirectory(atPath: directory.path)).isEmpty)
  }

  @Test(
    "stop ends only the gates checking the named worktrees — catches a cutoff stopping the merge gate of a task it lets finish"
  )
  func stopEndsOnlyNamedWorktrees() async throws {
    let directory = try TestTemporaryDirectory.make("gates")
    defer { TestTemporaryDirectory.remove(directory) }
    let processes = ScriptedProcesses([20: 1, 21: 1])
    let registry = RunningGateRegistry(directory: directory, processes: processes)
    _ = registry.register(pid: 20, toplevel: "/repo-plan-cut", tier: .slice, now: Self.now)
    _ = registry.register(pid: 21, toplevel: "/repo", tier: .merge, now: Self.now)

    let stopped = await registry.stop(in: ["/repo-plan-cut"])

    #expect(stopped.map(\.pid) == [20])
    #expect(processes.terminated == [20])
    #expect(registry.running().map(\.pid) == [21])
  }

  @Test(
    "the live process table reads this process's start time and none for a pid that isn't running — catches every gate read as already ended"
  )
  func liveStartTimes() {
    let processes = LiveGateProcesses()
    #expect(processes.startTime(of: getpid()) != nil)
    #expect(processes.startTime(of: Int32.max) == nil)
  }
}

@Suite("active run time box")
struct ActiveRunTimeBoxTests {
  @Test(
    "a plan's launch clock gives the box while it runs and none once it ended — catches a gate that never learns the run's cutoff"
  )
  func findsTheRunningBox() throws {
    let base = try TestTemporaryDirectory.make("active-box")
    defer { TestTemporaryDirectory.remove(base) }
    let layout = BrownfieldStateLayout(
      commonDir: base.appending(path: "common", directoryHint: .isDirectory),
      gitDir: base.appending(path: "gitdir", directoryHint: .isDirectory))
    let plan = layout.plan(slug: "spec")
    try FileManager.default.createDirectory(at: plan, withIntermediateDirectories: true)
    let clock = try Fixture.data("BrownfieldTrial/price-tracker-1-clock.json")
    try clock.write(to: plan.appending(path: RunClock.fileName))
    let box = try #require(try RunClock.decode(clock).runTimeBox)

    #expect(
      ActiveRunTimeBox.find(layout: layout, now: box.startedAt.addingTimeInterval(60)) == box)
    #expect(
      ActiveRunTimeBox.find(layout: layout, now: box.deadlines.endsAt.addingTimeInterval(1))
        == nil)
  }
}

@Suite("measured final gate in a clone")
struct MeasuredFinalGateReaderTests {
  @Test(
    "the gate runs a worktree's events hold measure its final, and a box found with that measure has its cutoff brought earlier — catches gates and qa runs reading the fixed 5 min reserve"
  )
  func readsTheGateHistory() throws {
    let worktree = try TestTemporaryDirectory.make("final-gate")
    defer { TestTemporaryDirectory.remove(worktree) }
    let events = URL(filePath: HarnessEventFiles(root: worktree).path(.gate, runID: nil))
    try FileManager.default.createDirectory(
      at: events.deletingLastPathComponent(), withIntermediateDirectories: true)
    let runs = try Fixture.data("BrownfieldTrial/send-money-2-gate-runs.jsonl")
    let merges =
      String(decoding: runs, as: UTF8.self).split(separator: "\n")
      .filter { !$0.contains("\"check final\"") }.joined(separator: "\n") + "\n"
    try Data(merges.utf8).write(to: events)

    #expect(MeasuredFinalGateReader.seconds(worktree: worktree) == 290)

    let layout = BrownfieldStateLayout(
      commonDir: worktree.appending(path: "common", directoryHint: .isDirectory),
      gitDir: worktree.appending(path: "gitdir", directoryHint: .isDirectory))
    let plan = layout.plan(slug: "spec")
    try FileManager.default.createDirectory(at: plan, withIntermediateDirectories: true)
    let clock = try Fixture.data("BrownfieldTrial/send-money-2-clock.json")
    try clock.write(to: plan.appending(path: RunClock.fileName))
    let box = try #require(try RunClock.decode(clock).runTimeBox)

    let sized = try #require(
      ActiveRunTimeBox.find(layout: layout, now: box.startedAt, finalSeconds: 290))
    #expect(sized.deadlines.cutoffAt == box.deadlines.cutoffAt.addingTimeInterval(-60))
  }
}

@Suite("area step results")
struct AreaStepResultsTests {
  @Test(
    "a recorded pass is found by its key, and another key finds none — catches a final that can't see what its merge passed"
  )
  func recordsAndFinds() throws {
    let directory = try TestTemporaryDirectory.make("area-steps")
    defer { TestTemporaryDirectory.remove(directory) }
    let store = AreaStepResults(directory: directory)

    store.record(AreaStepPass(runID: "20261005T030000Z-1", tier: "merge"), key: "abc")

    #expect(
      AreaStepResults(directory: directory).pass("abc")
        == AreaStepPass(runID: "20261005T030000Z-1", tier: "merge"))
    #expect(store.pass("def") == nil)
  }
}

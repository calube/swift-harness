import SwiftGateDomain
import Testing

/// A tiny linear-congruential generator so the property-style tests below are reproducible: the
/// same seed always drives the same sequence of shuffles, with no dependency on host randomness
/// or on `swift test`'s (absent, on this toolchain) shuffle support.
private struct SeededGenerator: RandomNumberGenerator {
  private var state: UInt64
  init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
  mutating func next() -> UInt64 {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    var value = state
    value ^= value >> 33
    value = value &* 0xFF51_AFD7_ED55_8CCD
    value ^= value >> 33
    return value
  }
}

@Suite("Plan scheduling")
struct PlanScheduleTests {
  private static func task(
    _ id: String, deps: [String] = [], writeSet: [String] = []
  ) -> LedgerTask {
    LedgerTask(
      id: id, deps: deps, writeSet: writeSet.isEmpty ? ["Sources/\(id)/"] : writeSet, gate: .push,
      tests: [], covers: [], estLines: 100, status: .pending, worktree: "../worktree-\(id)")
  }

  /// Every pair of tasks placed in the same wave, across the whole schedule.
  private static func waveMates(_ waves: [[String]], byID: [String: LedgerTask]) -> [(
    LedgerTask, LedgerTask
  )] {
    waves.flatMap { wave in
      wave.enumerated().flatMap { i, id in
        wave[(i + 1)...].map { (byID[id]!, byID[$0]!) }
      }
    }
  }

  // MARK: - Overlapping write sets never share a wave

  @Test(
    "two tasks that write the same file never land in the same wave — catches merge collisions")
  func smallestOverlapExample() throws {
    let a = Self.task("a", writeSet: ["Sources/Shared.swift"])
    let b = Self.task("b", writeSet: ["Sources/Shared.swift"])
    let waves = try PlanSchedule.schedule(tasks: [a, b], maxParallel: 3).get()
    #expect(waves.allSatisfy { !($0.contains("a") && $0.contains("b")) })
  }

  @Test("a directory write set overlaps a file under it, splitting the two tasks apart")
  func directoryVersusFileOverlap() throws {
    let dir = Self.task("dir-owner", writeSet: ["src/Foo/"])
    let file = Self.task("file-owner", writeSet: ["src/Foo/Bar.swift"])
    let sibling = Self.task("sibling", writeSet: ["src/Other/Bar.swift"])
    let waves = try PlanSchedule.schedule(tasks: [dir, file, sibling], maxParallel: 3).get()
    #expect(waves.allSatisfy { !($0.contains("dir-owner") && $0.contains("file-owner")) })
    // The non-colliding sibling is free to share a wave with either.
    #expect(waves.reduce(0) { $0 + $1.count } == 3)
  }

  @Test(
    "no wave ever holds two tasks whose write sets overlap, across many generated task graphs — catches merge collisions"
  )
  func noWaveHoldsOverlappingTasksAcrossManyGraphs() throws {
    let files = (0..<6).map { "File\($0).swift" }
    for seed: UInt64 in 0..<40 {
      var rng = SeededGenerator(seed: seed)
      var tasks: [LedgerTask] = []
      for index in 0..<12 {
        let id = "t\(index)"
        // Deps only point to lower-numbered tasks, so the graph is always acyclic.
        let deps = (0..<index).filter { _ in Bool.random(using: &rng) }.map { "t\($0)" }
        let fileCount = Int.random(in: 1...2, using: &rng)
        let writeSet = Set((0..<fileCount).map { _ in files.randomElement(using: &rng)! })
        tasks.append(Self.task(id, deps: deps, writeSet: Array(writeSet)))
      }
      let byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
      let waves = try PlanSchedule.schedule(tasks: tasks, maxParallel: 3).get()

      for (left, right) in Self.waveMates(waves, byID: byID) {
        #expect(
          !WriteSet.overlaps(left.writeSet, right.writeSet),
          "seed \(seed): \(left.id) and \(right.id) share a wave but overlap")
      }
      // Every task appears, exactly once, and never before a wave holding its own deps.
      #expect(Set(waves.flatMap { $0 }) == Set(tasks.map(\.id)))
      var scheduledSoFar: Set<String> = []
      for wave in waves {
        for id in wave {
          #expect(
            byID[id]!.deps.allSatisfy(scheduledSoFar.contains),
            "seed \(seed): \(id) scheduled before a dependency")
        }
        scheduledSoFar.formUnion(wave)
      }
    }
  }

  // MARK: - Width cap

  @Test("a width cap of 3 splits 7 independent tasks into waves of 3, 3 and 1")
  func widthCapSplitsIndependentTasks() throws {
    let tasks = (1...7).map { Self.task("t\($0)", writeSet: ["Sources/t\($0)/"]) }
    let waves = try PlanSchedule.schedule(tasks: tasks, maxParallel: 3).get()
    #expect(waves.map { $0.count } == [3, 3, 1])
    #expect(waves == [["t1", "t2", "t3"], ["t4", "t5", "t6"], ["t7"]])
  }

  // MARK: - Determinism over permuted inputs

  @Test("scheduling the same tasks in every order produces byte-identical waves")
  func outputIdenticalOverAllPermutations() throws {
    let tasks = [
      Self.task("a", writeSet: ["src/a.swift"]),
      Self.task("b", deps: ["a"], writeSet: ["src/a.swift"]),
      Self.task("c", deps: ["a"], writeSet: ["src/c.swift"]),
      Self.task("d", writeSet: ["src/d.swift"]),
      Self.task("e", deps: ["b", "c"], writeSet: ["src/e.swift"]),
    ]
    let reference = try PlanSchedule.schedule(tasks: tasks, maxParallel: 3).get()

    func permutations(_ items: [LedgerTask]) -> [[LedgerTask]] {
      guard items.count > 1 else { return [items] }
      var result: [[LedgerTask]] = []
      for i in items.indices {
        var rest = items
        let picked = rest.remove(at: i)
        for tail in permutations(rest) {
          result.append([picked] + tail)
        }
      }
      return result
    }

    for permuted in permutations(tasks) {
      let waves = try PlanSchedule.schedule(tasks: permuted, maxParallel: 3).get()
      #expect(waves == reference)
    }
  }

  @Test("scheduling is identical over many seeded shuffles of a larger task set")
  func outputIdenticalOverSeededShuffles() throws {
    let base = (0..<15).map { index in
      Self.task(
        "t\(index)", deps: index > 0 ? ["t\(index / 3)"] : [],
        writeSet: ["src/group\(index % 4)/"])
    }
    let reference = try PlanSchedule.schedule(tasks: base, maxParallel: 3).get()
    for seed: UInt64 in 0..<30 {
      var rng = SeededGenerator(seed: seed)
      let shuffled = base.shuffled(using: &rng)
      let waves = try PlanSchedule.schedule(tasks: shuffled, maxParallel: 3).get()
      #expect(waves == reference, "seed \(seed) produced a different schedule")
    }
  }

  // MARK: - Cycle and missing-dependency errors

  @Test("a dependency cycle fails, naming the cycle's task ids in order")
  func cycleNamesIdsInOrder() {
    let a = Self.task("a", deps: ["b"])
    let b = Self.task("b", deps: ["c"])
    let c = Self.task("c", deps: ["a"])
    let result = PlanSchedule.schedule(tasks: [a, b, c], maxParallel: 3)
    #expect(result == .failure(.cycle(ids: ["a", "b", "c"])))
  }

  @Test("a self-cycle fails, naming the single task id")
  func selfCycleNamesOwnId() {
    let a = Self.task("a", deps: ["a"])
    let result = PlanSchedule.schedule(tasks: [a], maxParallel: 3)
    #expect(result == .failure(.cycle(ids: ["a"])))
  }

  @Test("a missing dependency fails, naming both the task and the dependency it can't find")
  func missingDependencyNamesBothIds() {
    let a = Self.task("a", deps: ["ghost"])
    let result = PlanSchedule.schedule(tasks: [a], maxParallel: 3)
    #expect(result == .failure(.missingDependency(task: "a", dependency: "ghost")))
  }
}

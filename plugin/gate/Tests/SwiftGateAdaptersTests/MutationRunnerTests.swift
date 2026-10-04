import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

@Suite("MutationRunner")
struct MutationRunnerTests {
  private static let file = "Pkg/Sources/Core/Core.swift"
  private static let original = "func f(a: Int) -> Bool { a < 3 }\n"
  private static let selection = HostTestSelection(
    packagePath: "Pkg", targets: [TestTargetReference(name: "CoreTests", path: "Pkg/Tests")])
  private static let tree = ScratchTreeRequest(
    revision: "HEAD", revertTo: "HEAD", copiedPaths: [], revertedPaths: [])

  /// A project directory holding the unmutated file.
  private struct Seed {
    let root: URL

    init() throws {
      root = TestTemporaryDirectory.root
        .appending(path: "swiftgate-mutate-seed-\(UUID().uuidString)", directoryHint: .isDirectory)
      let file = root.appending(path: MutationRunnerTests.file)
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(MutationRunnerTests.original.utf8).write(to: file)
    }

    func remove() { TestTemporaryDirectory.remove(root) }
  }

  /// `count` distinct mutants of the file (boundary, negation, default), cycled.
  private static func jobs(_ count: Int, selections: [HostTestSelection] = [selection])
    -> [MutantJob]
  {
    let text = original
    let offsets: [(Int, String, String, MutationOperator)] = [
      (27, "<", "<=", .relationalBoundary),
      (25, "a < 3", "!(a < 3)", .negateConditional),
      (25, "a < 3", "false", .returnDefault),
    ]
    return (0..<count).map { index in
      let (offset, original, replacement, op) = offsets[index % offsets.count]
      let mutant = Mutant(
        file: file, text: text, utf8Offset: offset, original: original,
        replacement: replacement, operator: op)!
      return MutantJob(
        mutant: mutant, originalText: text, mutatedText: mutant.apply(to: text)!,
        selections: selections)
    }
  }

  private static func content(_ root: URL) -> String {
    (try? String(contentsOf: root.appending(path: file), encoding: .utf8)) ?? "<missing>"
  }

  private func run(
    _ jobs: [MutantJob], scratch: any ScratchWorktrees, toolchain: FakeMutationToolchain,
    workers: Int = 1, timeout: MutantTimeout = MutantTimeout()
  ) async -> MutationRunResult {
    await MutationRunner(scratch: scratch, toolchain: toolchain, workers: workers, timeout: timeout)
      .run(
        jobs, tree: Self.tree, projectPrefix: "",
        reportDirectory: TestTemporaryDirectory.root.appending(path: "mutate-reports"))
  }

  @Test(
    "tests failing on the mutated file kill it; passing ones let it survive; the file is restored after each — catches mutants leaking into the next mutant's build"
  )
  func killAndSurvive() async throws {
    let seed = try Seed()
    defer { seed.remove() }
    let toolchain = FakeMutationToolchain(test: { root, _ in
      // Only the boundary mutant is caught; the unmutated baseline passes.
      Self.content(root).contains("a <= 3")
        ? (.failed(failingTests: ["CoreTests.S/boundary()"]), .seconds(1))
        : (.passed(executed: 4), .seconds(1))
    })

    let result = await run(
      Self.jobs(2), scratch: CopyingScratchWorktrees(seed: seed.root), toolchain: toolchain)

    #expect(
      result.results.map(\.outcome) == [
        .killed(failingTests: ["CoreTests.S/boundary()"]), .survived(testsRun: 4),
      ])
    #expect(toolchain.tests.count == 3)
    #expect(toolchain.builds.count == 3)
  }

  @Test(
    "a mutant whose build fails is unviable, not killed, and the next mutant builds from the restored file — catches compile errors inflating the kill rate"
  )
  func unviable() async throws {
    let seed = try Seed()
    defer { seed.remove() }
    let contents = Mutex<[String]>([])
    let toolchain = FakeMutationToolchain(
      build: { root, _ in
        let text = Self.content(root)
        contents.withLock { $0.append(text) }
        return text.contains("<=") ? .failed(log: "error: nope") : .built
      },
      test: { root, _ in
        Self.content(root) == Self.original
          ? (.passed(executed: 2), .seconds(1)) : (.failed(failingTests: ["T.t()"]), .seconds(1))
      })
    let jobs = Self.jobs(2)

    let result = await run(
      jobs, scratch: CopyingScratchWorktrees(seed: seed.root), toolchain: toolchain)

    #expect(
      result.results.map(\.outcome) == [
        .unviable("error: nope"), .killed(failingTests: ["T.t()"]),
      ])
    #expect(contents.withLock { $0 } == [Self.original] + jobs.map(\.mutatedText))
  }

  @Test(
    "a mutant's tests get the timeout scaled from the unmutated run and a timeout counts as killed — catches an infinite-loop mutant hanging the gate or counting as survived"
  )
  func timeout() async throws {
    let seed = try Seed()
    defer { seed.remove() }
    let toolchain = FakeMutationToolchain(test: { root, _ in
      Self.content(root) == Self.original
        ? (.passed(executed: 1), .seconds(8)) : (.timedOut(after: .seconds(40)), .seconds(40))
    })

    let result = await run(
      Self.jobs(1), scratch: CopyingScratchWorktrees(seed: seed.root), toolchain: toolchain,
      timeout: MutantTimeout(floor: .seconds(20), multiplier: 5))

    #expect(result.results.map(\.outcome) == [.timedOut(after: .seconds(40))])
    #expect(toolchain.tests.map(\.timeout).last == .seconds(40))
    #expect(
      MutantTimeout(floor: .seconds(20), multiplier: 5).limit(baseline: .seconds(1)) == .seconds(20)
    )
  }

  @Test(
    "when the unmutated tests fail every mutant is not judged — catches a broken baseline reported as kills"
  )
  func brokenBaseline() async throws {
    let seed = try Seed()
    defer { seed.remove() }
    let toolchain = FakeMutationToolchain(test: { _, _ in
      (.failed(failingTests: ["T.flaky()"]), .seconds(1))
    })

    let result = await run(
      Self.jobs(3), scratch: CopyingScratchWorktrees(seed: seed.root), toolchain: toolchain)

    #expect(
      result.results.allSatisfy {
        if case .noEvidence(let reason) = $0.outcome { return reason.contains("fail unmutated") }
        return false
      })
    #expect(toolchain.tests.count == 1)
  }

  @Test(
    "the unmutated tests run once per package however many workers build it, only once no build is running, and every worker's timeouts scale from that run — catches each worker running the whole suite at once, or beside the other workers' compiles, and failing it for want of headroom"
  )
  func oneBaselinePerPackage() async throws {
    let seed = try Seed()
    defer { seed.remove() }
    let workers = 4
    // Holds every worker at its first build until all of them have one, so each takes work;
    // then keeps all but the first compiling until the unmutated tests start, or a while if
    // they wait for the compiles, as they must.
    let building = Mutex(0)
    let compiling = Mutex(0)
    let allBuilding = DispatchSemaphore(value: 0)
    let baselineStarted = DispatchSemaphore(value: 0)
    let baselines = Mutex<[Int]>([])
    let toolchain = FakeMutationToolchain(
      build: { _, _ in
        compiling.withLock { $0 += 1 }
        defer { compiling.withLock { $0 -= 1 } }
        let started = building.withLock { count in
          count += 1
          return count
        }
        if started == workers {
          for _ in 0..<workers { allBuilding.signal() }
        }
        if started <= workers {
          _ = allBuilding.wait(timeout: .now() + 60)  // swiftgate:allow safety.blocking-in-async — the fake toolchain runs builds off the pool
        }
        if (2...workers).contains(started) {
          _ = baselineStarted.wait(timeout: .now() + 2)  // swiftgate:allow safety.blocking-in-async — the fake toolchain runs builds off the pool
        }
        return .built
      },
      test: { root, _ in
        guard Self.content(root) == Self.original else {
          return (.failed(failingTests: ["T.t()"]), .seconds(1))
        }
        let alongside = compiling.withLock { $0 }
        baselines.withLock { $0.append(alongside) }
        for _ in 1..<workers { baselineStarted.signal() }
        return (.passed(executed: 1), .seconds(7))
      })

    let result = await run(
      Self.jobs(9), scratch: CopyingScratchWorktrees(seed: seed.root), toolchain: toolchain,
      workers: workers)

    #expect(Set(toolchain.builds).count == workers)
    // One run, with no compile beside it.
    #expect(baselines.withLock { $0 } == [0])
    #expect(result.results.allSatisfy { $0.outcome == .killed(failingTests: ["T.t()"]) })
    let mutantRuns = toolchain.tests.filter { $0.timeout != .seconds(900) }
    #expect(mutantRuns.count == 9)
    #expect(mutantRuns.allSatisfy { $0.timeout == .seconds(35) })
  }

  @Test(
    "workers each get their own scratch tree, every mutant runs exactly once, and workers never exceed the mutants — catches parallel workers colliding or duplicating runs"
  )
  func parallelWorkers() async throws {
    let seed = try Seed()
    defer { seed.remove() }
    let scratch = CopyingScratchWorktrees(seed: seed.root)
    let toolchain = FakeMutationToolchain(test: { root, _ in
      Self.content(root) == Self.original
        ? (.passed(executed: 1), .seconds(1)) : (.failed(failingTests: ["T.t()"]), .seconds(1))
    })

    let result = await run(Self.jobs(9), scratch: scratch, toolchain: toolchain, workers: 4)

    #expect(result.workers == 4)
    #expect(Set(scratch.trees).count == 4)
    #expect(result.results.count == 9)
    #expect(result.results.allSatisfy { $0.outcome == .killed(failingTests: ["T.t()"]) })
    let used = Set(toolchain.tests.map(\.root))
    #expect(used.isSubset(of: Set(scratch.trees)))

    let few = await run(Self.jobs(2), scratch: scratch, toolchain: toolchain, workers: 8)
    #expect(few.workers == 2)
  }

  @Test(
    "a mutant no test target reaches is noTests without a build, and a scratch tree that cannot be made leaves the rest not judged — catches both passing silently"
  )
  func noTestsAndScratchFailure() async throws {
    let seed = try Seed()
    defer { seed.remove() }
    let toolchain = FakeMutationToolchain()
    let jobs = Self.jobs(1, selections: []) + Self.jobs(1)

    let result = await run(
      jobs, scratch: CopyingScratchWorktrees(seed: seed.root, failure: .fileSystem("disk full")),
      toolchain: toolchain)

    #expect(result.results.first?.outcome == .noTests)
    guard case .noEvidence(let reason) = result.results.last?.outcome else {
      Issue.record("expected no evidence, got \(String(describing: result.results.last))")
      return
    }
    #expect(reason.contains("disk full"))
    #expect(toolchain.builds.isEmpty)
  }

  @Test(
    "a scratch file that differs from the working tree the mutant was made from is not mutated — catches mutating stale bytes"
  )
  func staleScratch() async throws {
    let seed = try Seed()
    defer { seed.remove() }
    try Data("func g() {}\n".utf8).write(to: seed.root.appending(path: Self.file))

    let result = await run(
      Self.jobs(1), scratch: CopyingScratchWorktrees(seed: seed.root),
      toolchain: FakeMutationToolchain())

    guard case .noEvidence(let reason) = result.results.first?.outcome else {
      Issue.record("expected no evidence")
      return
    }
    #expect(reason.contains("differs"))
  }
}

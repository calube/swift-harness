import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

@testable import SwiftGateCLI

@Suite("brownfield merge and final tiers")
struct BrownfieldMergeCheckTests {
  /// A temp directory holding the clone's state, the worktree path and the scratch tree path.
  /// Nothing here resolves this checkout's git dir.
  private struct Clone {
    let base: URL
    var root: URL { base.appending(path: "repo", directoryHint: .isDirectory) }
    var scratch: URL { base.appending(path: "scratch", directoryHint: .isDirectory) }
    var layout: BrownfieldStateLayout {
      BrownfieldStateLayout(
        commonDir: base.appending(path: "common", directoryHint: .isDirectory),
        gitDir: base.appending(path: "gitdir", directoryHint: .isDirectory))
    }

    init() throws {
      base = TestTemporaryDirectory.root.appending(
        path: "swiftgate-brownfield-merge-\(UUID().uuidString)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    func inScratch(_ request: AreaCommandRequest) -> Bool {
      request.workingDirectory.hasPrefix(scratch.path(percentEncoded: false))
    }
  }

  /// A wait that ends only when its task is cancelled: a bound that never runs out first.
  private static func untilCancelled() async throws {
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    await withTaskCancellationHandler {
      for await _ in stream {}
    } onCancel: {
      continuation.finish()
    }
    throw CancellationError()
  }

  private static func area(
    _ name: String, test: String? = "test-all", testFiles: String? = "check {files}",
    lint: String? = "lint {files}", build: String? = "build", e2e: String? = nil
  ) -> BrownfieldArea {
    BrownfieldArea(
      name: name, root: name, language: .javascript, kind: .node, test: test,
      testFiles: testFiles, lint: lint, build: build, e2e: e2e, testGlobs: ["\(name)/tests/**"],
      packs: [], xcode: nil)
  }

  private static func run(
    _ clone: Clone, tier: CheckTier, areas: [BrownfieldArea], changed: [String],
    runner: FakeAreaCommandRunner, sliceBuildsOnly: Bool = false,
    buildsOnly: (@Sendable (BrownfieldArea) -> Bool)? = nil,
    context: GateRun.Context? = nil, areaRunner: (any AreaCommandRunning)? = nil,
    bound:
      (@Sendable (_ area: String, _ step: AreaStep, _ tree: AreaCommandTree) -> AreaCommandBound)? =
      nil,
    reuse: AreaStepReuse? = nil, headTree: String? = nil
  ) async throws -> GateRunParts {
    let runner = areaRunner ?? runner
    let git = FakeGit(
      changed: changed, mergeBase: "base0",
      addedSince: changed.map { AddedLines(path: $0, ranges: [1...1]) })
    let scratch = FakeScratchWorktrees(root: clone.scratch)
    let config = BrownfieldConfig(
      brownfield: BrownfieldSettings(
        discoveredAt: "base0", sliceBudgetSeconds: 30, timeBudgetMinutes: 0, sensitive: []),
      areas: areas, allow: [], buildPresets: [:])
    var scratchBound: (@Sendable (String, AreaStep) -> AreaCommandBound)?
    if let bound {
      scratchBound = { area, step in bound(area, step, .scratch) }
    }
    let dependencies = BrownfieldMergeCheck.Dependencies(
      config: config, layout: clone.layout, git: git, runner: runner,
      baseline: BaselineStore(layout: clone.layout, runner: runner, scratch: scratch),
      prove: BrownfieldProve.Dependencies(
        git: git, scratch: scratch, runner: runner, readFile: { _ in "it('works')\n" },
        deadline: .seconds(5), bound: scratchBound),
      trackedTree: TrackedTreeSnapshot(files: [:]), tree: { _ in "tree0" },
      sliceBuildsOnly: buildsOnly ?? { _ in sliceBuildsOnly }, deadline: .seconds(5),
      headTree: headTree, bound: bound,
      reuse: reuse)
    return try await BrownfieldMergeCheck.run(
      root: clone.root, tier: tier, base: "main",
      context: context ?? GateRun.Context(runID: "run", directory: clone.base),
      dependencies: dependencies)
  }

  private static func gating(_ parts: GateRunParts) -> [String] {
    parts.findings.filter { $0.severity.failsGate }.map { "\($0.ruleID) \($0.file)" }.sorted()
  }

  private static func verdict(_ parts: GateRunParts) -> Verdict {
    Verdict.merged(parts.tiers.map(\.verdict) + (gating(parts).isEmpty ? [] : [.red]))
  }

  @Test(
    "a build-only area's changed tests run and prove at merge — catches tests that slice moved and nobody ran"
  )
  func buildOnlyAreaProvesAtMerge() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let changed = ["web/src/lib.js", "web/tests/new.test.js"]
    let moved = FakeAreaCommandRunner { _ in .passed }
    let context = GateRun.Context(runID: "run", directory: clone.base)

    let parts = try await Self.run(
      clone, tier: .merge, areas: [Self.area("web")], changed: changed, runner: moved,
      sliceBuildsOnly: true, context: context)

    #expect(
      moved.requests.contains { $0.step == .testFiles && clone.inScratch($0) },
      "prove ran the moved test in a reverted tree")
    #expect(moved.requests.contains { $0.step == .test && !clone.inScratch($0) })
    #expect(Self.gating(parts) == ["neutral.not-proven web/tests/new.test.js"])
    #expect(
      context.proofs.results
        == [
          ProvedTest(
            test: "tests/new.test.js", target: "web", outcome: .passesReverted,
            proofBase: "base0", assertion: nil)
        ],
      "the gate run records the moved test's proof")

    let proven = FakeAreaCommandRunner { _ in .passed }
    _ = try await Self.run(
      clone, tier: .merge, areas: [Self.area("web")], changed: changed, runner: proven,
      sliceBuildsOnly: false)
    #expect(
      !proven.requests.contains { $0.step == .testFiles },
      "an area slice already proved isn't proved again")
  }

  /// The bounds the price-tracker trial's warm-up times give, with no time box running.
  private static let trialBound:
    @Sendable (_ area: String, _ step: AreaStep, _ tree: AreaCommandTree) -> AreaCommandBound = {
      area, step, tree in
      let times =
        (try? WarmupTimesFile.decode(
          Fixture.data("BrownfieldTrial/price-tracker-1-warmup.json"),
          tree: "20356747eb132f654aa83d669d3156442e11a963")) ?? WarmupTimesFile(tree: "")
      return AreaCommandBounds(times: times, box: nil, tier: .merge, fallback: .seconds(3600))
        .bound(area: area, step: step, tree: tree, now: Date(timeIntervalSince1970: 0))
    }

  @Test(
    "a test step that hangs at the head is held only to its bound and is RED naming the step, the bound and the output's tail — catches a hung test holding the merge gate for the flat hour"
  )
  func hungTestStepIsRedAtItsBound() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let hung = FakeAreaCommandRunner { request in
      request.step == .test && !clone.inScratch(request)
        ? .timedOut(tail: "◇ Test spinsUntilStarted() started.") : .passed
    }

    let parts = try await Self.run(
      clone, tier: .merge, areas: [Self.area("AppFeature")], changed: ["AppFeature/src/a.js"],
      runner: hung, bound: Self.trialBound)

    let test = try #require(hung.requests.first { $0.step == .test && !clone.inScratch($0) })
    #expect(test.deadline == .milliseconds(5 * 31_715))
    #expect(Self.verdict(parts) == .red)
    let finding = try #require(parts.findings.first { $0.ruleID == "area.test-failed" })
    #expect(finding.message.contains("test"))
    #expect(finding.message.contains("159 s"))
    #expect(finding.message.contains("5 × AppFeature's 31.7 s warm test"))
    #expect(finding.message.contains("spinsUntilStarted() started"))
  }

  @Test(
    "a step the box leaves less time than its measured run isn't started and the tier is BLOCKED saying so — catches a gate step started only to be killed at the cutoff"
  )
  func stepThatCannotFinishIsNotStarted() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let runner = FakeAreaCommandRunner { _ in .passed }
    let short: @Sendable (String, AreaStep, AreaCommandTree) -> AreaCommandBound = { _, step, _ in
      step == .test
        ? AreaCommandBound(
          duration: .seconds(20), reason: "the 20 s left before the run's cutoff",
          expected: .milliseconds(31_715))
        : AreaCommandBound(duration: .seconds(600), reason: "the floor")
    }

    let parts = try await Self.run(
      clone, tier: .merge, areas: [Self.area("AppFeature")], changed: ["AppFeature/src/a.js"],
      runner: runner, bound: short)

    #expect(!runner.requests.contains { $0.step == .test })
    #expect(Self.verdict(parts) == .blocked)
    #expect(
      parts.findings.contains {
        $0.ruleID == CheckRun.notRunRuleID && $0.message.contains("AppFeature test")
          && $0.message.contains("20 s left")
      })
  }

  @Test(
    "a moved test's prove runs in the scratch tree under the scratch bound, and a hang there is RED prove.hangs-at-base recorded per test — catches prove waiting out a test that spins forever with the source reverted"
  )
  func proveHangAtBaseIsAResult() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let changed = ["AppFeature/src/lib.js", "AppFeature/tests/spins.test.js"]
    let hung = FakeAreaCommandRunner { request in
      request.step == .testFiles && clone.inScratch(request)
        ? .timedOut(tail: "◇ Test spins() started.") : .passed
    }
    let context = GateRun.Context(runID: "run", directory: clone.base)

    let parts = try await Self.run(
      clone, tier: .merge, areas: [Self.area("AppFeature")], changed: changed, runner: hung,
      sliceBuildsOnly: true, context: context, bound: Self.trialBound)

    let prove = try #require(hung.requests.first { $0.step == .testFiles && clone.inScratch($0) })
    #expect(prove.deadline == .milliseconds(240_679 + 5 * 31_715))
    #expect(Self.gating(parts) == ["prove.hangs-at-base AppFeature/tests/spins.test.js"])
    let finding = try #require(parts.findings.first { $0.ruleID == "prove.hangs-at-base" })
    #expect(finding.message.contains("400 s"))
    #expect(context.proofs.results.map(\.outcome) == [.hangsAtBase])
  }

  @Test(
    "final takes each area command a merge passed on the same inputs and runs only the rest, naming what it reused — catches final rerunning every step at a tree whose merge just passed"
  )
  func finalReusesMergePasses() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let areas = [Self.area("web", e2e: "e2e-web"), Self.area("api")]
    let changed = ["web/src/lib.js"]
    let store = MemoryAreaSteps()
    let inputs = GateReuse.Inputs(
      tier: .merge, treeHash: "tree1", mergeBase: "base0", sourceHash: "bin1",
      stateFiles: ["config": "c1"])

    _ = try await Self.run(
      clone, tier: .merge, areas: areas, changed: changed,
      runner: FakeAreaCommandRunner { _ in .passed },
      reuse: AreaStepReuse(inputs: inputs, store: store, runID: "merge-run"))
    let final = FakeAreaCommandRunner { _ in .passed }
    let parts = try await Self.run(
      clone, tier: .final, areas: areas, changed: changed, runner: final,
      reuse: AreaStepReuse(inputs: inputs, store: store, runID: "final-run"))

    let ran = Set(final.requests.map { "\($0.area) \($0.step.rawValue)" })
    #expect(ran == ["web e2e", "api build", "api test"])
    #expect(Self.verdict(parts) == .green)
    let reused = parts.findings.filter { $0.ruleID == GateReuse.ruleID }
    #expect(reused.count == 3, "web build, test and lint")
    #expect(reused.allSatisfy { $0.message.contains("merge-run") })
  }

  @Test(
    "final takes a test step a merge passed on the same inputs even when the box has less time left than the step's measure, and refuses one with no pass naming final, not merge — catches final BLOCKED for a step that already passed on its tree"
  )
  func finalReusesBeforeTheTimeBound() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let areas = [Self.area("App")]
    let changed = ["App/src/lib.js"]
    let store = MemoryAreaSteps()
    let inputs = GateReuse.Inputs(
      tier: .merge, treeHash: "tree1", mergeBase: "base0", sourceHash: "bin1",
      stateFiles: ["config": "c1"])
    let short: @Sendable (String, AreaStep, AreaCommandTree) -> AreaCommandBound = { _, step, _ in
      step == .test
        ? AreaCommandBound(
          duration: .seconds(105), reason: "the 105 s left before the run's box ends",
          expected: .milliseconds(191_140))
        : AreaCommandBound(duration: .seconds(600), reason: "the floor")
    }
    _ = try await Self.run(
      clone, tier: .merge, areas: areas, changed: changed,
      runner: FakeAreaCommandRunner { _ in .passed },
      reuse: AreaStepReuse(inputs: inputs, store: store, runID: "merge-run"))

    let final = FakeAreaCommandRunner { _ in .passed }
    let parts = try await Self.run(
      clone, tier: .final, areas: areas, changed: changed, runner: final, bound: short,
      reuse: AreaStepReuse(inputs: inputs, store: store, runID: "final-run"))

    #expect(!final.requests.contains { $0.step == .test })
    #expect(Self.verdict(parts) == .green)
    #expect(
      parts.findings.contains {
        $0.ruleID == GateReuse.ruleID && $0.message.contains("App test passed in merge")
      })

    let unpassed = FakeAreaCommandRunner { _ in .passed }
    let refused = try await Self.run(
      clone, tier: .final, areas: areas, changed: changed, runner: unpassed, bound: short)
    #expect(!unpassed.requests.contains { $0.step == .test })
    #expect(Self.verdict(refused) == .blocked)
    let refusal = try #require(refused.findings.first { $0.ruleID == CheckRun.notRunRuleID })
    #expect(refusal.message.hasPrefix("final: App test not started"), "\(refusal.message)")
  }

  @Test(
    "on the third price-tracker trial's areas, after a merge gate that touched the client and feature packages, the cutoff's price of final names LogClient's build and test as the only steps left, exactly the steps final then runs — catches a price whose keys drift from the ones final looks up"
  )
  func finalPriceNamesTheStepsFinalRuns() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let config = try TOMLConfigDecoder().decodeBrownfield(
      try Fixture.text("BrownfieldTrial/price-tracker-3-config.toml"))
    let changed = [
      "Packages/APIClient/Sources/APIClientLive/CoinGeckoLive.swift",
      "Packages/AppFeature/Sources/AppCore/WatchlistFeature.swift",
    ]
    let store = MemoryAreaSteps()
    let inputs = GateReuse.Inputs(
      tier: .merge, treeHash: "tree1", mergeBase: "base0", sourceHash: "bin1",
      stateFiles: ["config": "c1"])
    _ = try await Self.run(
      clone, tier: .merge, areas: config.areas, changed: changed,
      runner: FakeAreaCommandRunner { _ in .passed },
      reuse: AreaStepReuse(inputs: inputs, store: store, runID: "merge-run"))

    let priced = FinalGateReuse.areas(
      config.areas,
      inputs: GateReuse.Inputs(
        tier: .final, treeHash: "tree1", mergeBase: "base0", sourceHash: "bin1",
        stateFiles: ["config": "c1"]),
      repositoryRoot: clone.root.path(percentEncoded: false), layout: clone.layout,
      passed: { store.pass($0) != nil })
    let final = FakeAreaCommandRunner { _ in .passed }
    _ = try await Self.run(
      clone, tier: .final, areas: config.areas, changed: changed, runner: final,
      reuse: AreaStepReuse(inputs: inputs, store: store, runID: "final-run"))

    #expect(priced.map(\.name) == config.areas.map(\.name))
    let left = Set(priced.flatMap { area in area.unreused.map { "\(area.name) \($0.rawValue)" } })
    #expect(left == ["LogClient build", "LogClient test"])
    #expect(left == Set(final.requests.map { "\($0.area) \($0.step.rawValue)" }))
  }

  @Test(
    "each gate step is labelled by what it built: final's reused area steps read reused, a prove that ran nothing reads none, and a prove whose reverted SwiftPM run builds in a fresh scratch tree reads cold — catches 0 s steps labelled cold or none, which skew warm and cold gate times"
  )
  func stepsAreLabelledByWhatTheyBuilt() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let areas = [Self.area("web"), Self.area("api")]
    let store = MemoryAreaSteps()
    let inputs = GateReuse.Inputs(
      tier: .merge, treeHash: "tree1", mergeBase: "base0", sourceHash: "bin1",
      stateFiles: ["config": "c1"])
    _ = try await Self.run(
      clone, tier: .merge, areas: areas, changed: ["web/src/lib.js"],
      runner: FakeAreaCommandRunner { _ in .passed },
      reuse: AreaStepReuse(inputs: inputs, store: store, runID: "merge-run"))
    let finalContext = GateRun.Context(runID: "final", directory: clone.base)
    _ = try await Self.run(
      clone, tier: .final, areas: areas, changed: ["web/src/lib.js"],
      runner: FakeAreaCommandRunner { _ in .passed }, context: finalContext,
      reuse: AreaStepReuse(inputs: inputs, store: store, runID: "final-run"))
    let reused = finalContext.steps.steps.filter { $0.area == "web" && $0.milliseconds == 0 }
    #expect(reused.count == 3, "web build, test and lint")
    #expect(reused.allSatisfy { $0.derivedData == .reused }, "\(reused.map(\.derivedData))")

    let app = BrownfieldArea(
      name: "app", root: "app", language: .swift, kind: .xcode, test: "test-all",
      testFiles: "check {files}", lint: nil, build: "build", e2e: nil,
      testGlobs: ["app/tests/**"], packs: [], xcode: nil)
    let nothing = GateRun.Context(runID: "nothing", directory: clone.base)
    _ = try await Self.run(
      clone, tier: .merge, areas: [app], changed: ["app/src/a.swift"],
      runner: FakeAreaCommandRunner { _ in .passed }, sliceBuildsOnly: true, context: nothing)
    let idle = try #require(nothing.steps.steps.first { $0.step == .prove })
    #expect(idle.derivedData == .none)

    let package = BrownfieldArea(
      name: "kit", root: "kit", language: .swift, kind: .swiftpm, test: "swift test",
      testFiles: "check {files}", lint: nil, build: "swift build", e2e: nil,
      testGlobs: ["kit/tests/**"], packs: [], xcode: nil)
    let proving = GateRun.Context(runID: "proving", directory: clone.base)
    let runner = FakeAreaCommandRunner { _ in .passed }
    _ = try await Self.run(
      clone, tier: .merge, areas: [package], changed: ["kit/src/a.swift", "kit/tests/a.swift"],
      runner: runner, sliceBuildsOnly: true, context: proving)
    #expect(runner.requests.contains { clone.inScratch($0) }, "prove ran in a scratch tree")
    let built = try #require(proving.steps.steps.first { $0.step == .prove })
    #expect(built.derivedData == .cold)
  }

  @Test(
    "a prove run the box leaves less time than its measured cold run isn't started and the tier is BLOCKED — catches a prove started at the cutoff only to be killed"
  )
  func proveThatCannotFinishIsNotStarted() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let runner = FakeAreaCommandRunner { _ in .passed }
    let short: @Sendable (String, AreaStep, AreaCommandTree) -> AreaCommandBound = {
      _, _, tree in
      tree == .scratch
        ? AreaCommandBound(
          duration: .seconds(90), reason: "the 90 s left before the run's cutoff",
          expected: .milliseconds(240_679))
        : AreaCommandBound(duration: .seconds(600), reason: "the floor")
    }

    let parts = try await Self.run(
      clone, tier: .merge, areas: [Self.area("AppFeature")],
      changed: ["AppFeature/src/lib.js", "AppFeature/tests/new.test.js"], runner: runner,
      sliceBuildsOnly: true, bound: short)

    #expect(!runner.requests.contains { clone.inScratch($0) })
    #expect(Self.verdict(parts) == .blocked)
    #expect(parts.findings.contains { $0.message.contains("90 s left") })
  }

  @Test(
    "an area's test clone is asked for before its build runs, its test runs on that clone, and the clone goes back when the area is done — catches a merge gate's test step paying its clone's boot after the build"
  )
  func testCloneWarmsDuringTheBuild() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let config = try Fixture.text("BrownfieldTrial/aidoku-validation-config.toml")
    func command(_ key: String) throws -> String {
      try #require(
        config.split(separator: "\n").first { $0.hasPrefix("\(key) = \"") }
          .map { String($0.dropFirst(key.count + 4).dropLast()) })
    }
    let leases = FakeTestDeviceLeases()
    // A wall clock would let a loaded machine run out the step's 5 s device wait, turning the
    // test step red and sending it to a merge-base rerun that leases a clone of its own.
    let still = SimHoldClock(now: { .zero }, sleep: { _ in try await Self.untilCancelled() })
    let askedAtBuild = Mutex<[Int]>([])
    let base = FakeAreaCommandRunner { request in
      if request.step == .build { askedAtBuild.withLock { $0.append(leases.destinations.count) } }
      return .passed
    }
    let area = Self.area(
      "app", test: try command("test"), testFiles: nil, lint: nil, build: try command("build"))

    _ = try await Self.run(
      clone, tier: .merge, areas: [area], changed: ["app/Sources/View.swift"], runner: base,
      areaRunner: LeasedDeviceAreaRunner(base: base, leases: leases, clock: still))

    #expect(askedAtBuild.withLock { $0 } == [1])
    let test = try #require(base.requests.first { $0.step == .test })
    #expect(!clone.inScratch(test), "\(test.workingDirectory)")
    #expect(
      test.command.contains("-destination 'id=\(FakeDevices.device.udid)'"), "\(test.command)")
    #expect((leases.entered, leases.left) == (1, 1))
  }

  @Test(
    "final runs every area and its e2e while merge runs only the touched area — catches final narrowing to the plan's diff"
  )
  func finalRunsEveryArea() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let areas = [Self.area("web", e2e: "e2e-web"), Self.area("api", e2e: "e2e-api")]
    let changed = ["web/src/lib.js"]

    let merge = FakeAreaCommandRunner { _ in .passed }
    _ = try await Self.run(clone, tier: .merge, areas: areas, changed: changed, runner: merge)
    #expect(Set(merge.requests.map(\.area)) == ["web"])
    #expect(!merge.requests.contains { $0.step == .e2e })

    let final = FakeAreaCommandRunner { _ in .passed }
    let context = GateRun.Context(runID: "run", directory: clone.base)
    let parts = try await Self.run(
      clone, tier: .final, areas: areas, changed: changed, runner: final, context: context)
    let ran = Set(final.requests.map { "\($0.area) \($0.step.rawValue)" })
    #expect(
      ran.isSuperset(of: [
        "web build", "web test", "web e2e", "api build", "api test", "api e2e", "web lint",
      ]))
    #expect(Self.verdict(parts) == .green)
    let timed = Set(
      context.steps.steps.compactMap { step in step.area.map { "\($0) \(step.step)" } })
    #expect(timed.isSuperset(of: ["api areaBuild", "api areaTest", "web areaBuild"]))
  }

  @Test(
    "final hands each area's test and e2e totals, read from the reports the step wrote, to the run, by area then step — catches the trial's kept report with no count of the tests an area ran"
  )
  func finalRecordsEachAreasTestTotals() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let swiftTest = "swift test --xunit-output {junit}"
    let areas = [
      Self.area("web", test: swiftTest, e2e: "e2e --junit {junit}"),
      Self.area("api", test: swiftTest),
    ]
    let reports = try ["APIClient.test.xml", "APIClient.test-swift-testing.xml"].map {
      try Fixture.data("BrownfieldTrial/send-money-2-junit/\($0)")
    }
    let runner = FakeAreaCommandRunner { request in
      if let junit = request.junitPath {
        try? FileManager.default.createDirectory(
          atPath: (junit as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let companion = JUnitReports.companionPaths(of: junit)[0]
        FileManager.default.createFile(atPath: junit, contents: reports[0])
        FileManager.default.createFile(atPath: companion, contents: reports[1])
      }
      return .passed
    }
    let context = GateRun.Context(runID: "run", directory: clone.base)

    _ = try await Self.run(
      clone, tier: .final, areas: areas, changed: ["web/src/lib.js"], runner: runner,
      context: context)

    let seven = JUnitCounts(tests: 7, failures: 0, skipped: 0)
    #expect(
      context.areaTests.all == [
        AreaTestCounts(area: "api", step: .test, counts: seven),
        AreaTestCounts(area: "web", step: .test, counts: seven),
        AreaTestCounts(area: "web", step: .e2e, counts: seven),
      ])
  }

  @Test(
    "final that reuses a merge's passes still hands the run each reused area's test totals, as the merge's reports counted them and marked with the merge run they came from, beside the totals of the steps it ran — catches the trial's final report counting only the 1 area it ran again"
  )
  func finalCarriesReusedAreaTestTotals() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let swiftTest = "swift test --xunit-output {junit}"
    let areas = [
      Self.area("web", test: swiftTest, e2e: "e2e --junit {junit}"),
      Self.area("api", test: swiftTest),
    ]
    let reports = try ["APIClient.test.xml", "APIClient.test-swift-testing.xml"].map {
      try Fixture.data("BrownfieldTrial/send-money-2-junit/\($0)")
    }
    let runner = FakeAreaCommandRunner { request in
      if let junit = request.junitPath {
        try? FileManager.default.createDirectory(
          atPath: (junit as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let companion = JUnitReports.companionPaths(of: junit)[0]
        FileManager.default.createFile(atPath: junit, contents: reports[0])
        FileManager.default.createFile(atPath: companion, contents: reports[1])
      }
      return .passed
    }
    let store = MemoryAreaSteps()
    let inputs = GateReuse.Inputs(
      tier: .merge, treeHash: "tree1", mergeBase: "base0", sourceHash: "bin1",
      stateFiles: ["config": "c1"])
    let merged = GateRun.Context(runID: "merge-run", directory: clone.base)
    _ = try await Self.run(
      clone, tier: .merge, areas: areas, changed: ["web/src/lib.js"], runner: runner,
      context: merged, reuse: AreaStepReuse(inputs: inputs, store: store, runID: "merge-run"))
    let final = GateRun.Context(runID: "final-run", directory: clone.base)

    _ = try await Self.run(
      clone, tier: .final, areas: areas, changed: ["web/src/lib.js"], runner: runner,
      context: final, reuse: AreaStepReuse(inputs: inputs, store: store, runID: "final-run"))

    let seven = JUnitCounts(tests: 7, failures: 0, skipped: 0)
    #expect(merged.areaTests.all == [AreaTestCounts(area: "web", step: .test, counts: seven)])
    #expect(
      final.areaTests.all == [
        AreaTestCounts(area: "api", step: .test, counts: seven),
        AreaTestCounts(area: "web", step: .test, counts: seven).reused(from: "merge-run"),
        AreaTestCounts(area: "web", step: .e2e, counts: seven),
      ])
  }

  @Test(
    "a dropped step reports area.step-dropped and never gates — catches a missing command read as a pass with no report line, or as a failure"
  )
  func droppedStepIsReportedAndNeverGates() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let runner = FakeAreaCommandRunner { _ in .passed }

    let parts = try await Self.run(
      clone, tier: .merge, areas: [Self.area("web", lint: nil, build: nil)],
      changed: ["web/src/lib.js"], runner: runner)

    let dropped = parts.findings.filter { $0.ruleID == BrownfieldRuleID.stepDropped.rawValue }
    #expect(dropped.count == 2)
    #expect(dropped.allSatisfy { $0.severity == .nit })
    #expect(dropped.map(\.message).joined().contains("lint"))
    #expect(dropped.map(\.message).joined().contains("build"))
    #expect(Self.verdict(parts) == .green)
  }

  @Test(
    "a failure the merge base shares doesn't gate and 1 only the head has does — catches merge gating on known failures, or the baseline absorbing new ones"
  )
  func baselineDecidesWhichFailuresGate() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let runner = FakeAreaCommandRunner { request in
      switch request.step {
      case .build: .failed(exit: 1, tail: "known build failure", junit: nil)
      case .test where !request.workingDirectory.hasPrefix(clone.scratch.path):
        .failed(exit: 1, tail: "new test failure", junit: nil)
      default: .passed
      }
    }

    let parts = try await Self.run(
      clone, tier: .merge, areas: [Self.area("web")], changed: ["web/src/lib.js"],
      runner: runner)

    #expect(Self.gating(parts) == ["area.test-failed web"])
    #expect(
      parts.findings.contains {
        $0.ruleID == BrownfieldRuleID.baselineSummary.rawValue && $0.message.contains("build")
      })
    #expect(Self.verdict(parts) == .red)
  }

  @Test(
    "a test step failing whole at the head and the merge base is excused at merge with both runs' evidence named, and gates final — catches final GREEN over a test step that proved nothing"
  )
  func wholeTestStepGatesFinal() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let runner = FakeAreaCommandRunner { request in
      request.step == .test
        ? .failed(exit: 65, tail: "Testing failed: runner encountered an error", junit: nil)
        : .passed
    }
    let mergeContext = GateRun.Context(
      runID: "merge", directory: clone.base.appending(path: "runs/merge"))
    let merge = try await Self.run(
      clone, tier: .merge, areas: [Self.area("web")], changed: ["web/src/lib.js"],
      runner: runner, context: mergeContext)

    #expect(Self.verdict(merge) == .green)
    let summary = try #require(
      merge.findings.first { $0.ruleID == BrownfieldRuleID.baselineSummary.rawValue })
    let headTail = mergeContext.directory.appending(path: "baseline-evidence/web.test.txt")
    #expect(
      try String(contentsOf: headTail, encoding: .utf8).contains("runner encountered an error"))
    #expect(summary.message.contains(headTail.path(percentEncoded: false)))
    #expect(summary.message.contains(clone.layout.baselineDirectory.path(percentEncoded: false)))

    let finalContext = GateRun.Context(
      runID: "final", directory: clone.base.appending(path: "runs/final"))
    let final = try await Self.run(
      clone, tier: .final, areas: [Self.area("web")], changed: ["web/src/lib.js"],
      runner: runner, context: finalContext)

    #expect(Self.verdict(final) == .red)
    #expect(
      Self.gating(final) == ["baseline.whole-step \(clone.layout.baseline(tree: "tree0").path)"])
    let whole = try #require(
      final.findings.first { $0.ruleID == BrownfieldRuleID.baselineWholeStep.rawValue })
    #expect(
      whole.message.contains(
        finalContext.directory.appending(path: "baseline-evidence/web.test.txt")
          .path(percentEncoded: false)))
  }

  @Test(
    "final reports a lint whose tool isn't on PATH at the head and the merge base as not installed, never absorbed — catches a final GREEN with lint absorbed as the whole step every gate"
  )
  func lintNotInstalledIsReported() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let missing = try Fixture.areaRun("swift/lint-not-installed")
    let runner = FakeAreaCommandRunner { request in request.step == .lint ? missing : .passed }

    let parts = try await Self.run(
      clone, tier: .final, areas: [Self.area("web", lint: "swiftlint lint {files}")],
      changed: ["web/src/lib.js"], runner: runner)

    #expect(runner.requests.contains { $0.step == .lint && clone.inScratch($0) })
    #expect(parts.baselineCount == 0)
    #expect(!parts.findings.contains { $0.ruleID == BrownfieldRuleID.baselineSummary.rawValue })
    #expect(
      parts.findings.contains {
        $0.ruleID == BrownfieldRuleID.stepDropped.rawValue && $0.message.contains("web lint")
          && $0.message.contains("isn't installed")
      })
    #expect(Self.verdict(parts) == .green)
  }

  @Test(
    "merge and final hand gate.run the count of failures the baseline absorbed, 0 when none failed — catches the final gate of the fifth memos trial, which absorbed 3 and wrote no baselineCount"
  )
  func baselineCountReachesTheGateRun() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let known = FakeAreaCommandRunner { request in
      request.step == .build ? .failed(exit: 1, tail: "known build failure", junit: nil) : .passed
    }
    for tier in [CheckTier.merge, .final] {
      let absorbed = try await Self.run(
        clone, tier: tier, areas: [Self.area("web"), Self.area("api")],
        changed: ["web/src/lib.js"], runner: known)
      #expect(Self.verdict(absorbed) == .green, "\(tier)")
      #expect(absorbed.baselineCount == (tier == .final ? 2 : 1), "\(tier)")
    }

    let clean = try await Self.run(
      clone, tier: .merge, areas: [Self.area("web")], changed: ["web/src/lib.js"],
      runner: FakeAreaCommandRunner { _ in .passed })
    #expect(clean.baselineCount == 0)
  }
}

/// The iOS trial's plan branch, rebuilt in a real repository: a contract commit on the plan base,
/// then 2 task branches merged with `--no-ff`, the first adding a test with its source and the
/// second only source.
private struct TrialPlanBranch {
  static let environment = [
    "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
    "HOME": TestTemporaryDirectory.sharedHome.path,
    "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
  ]
  static let test = "AidokuTests/LargeDownloadConfirmationTests.swift"

  let root: URL
  let runner = LiveProcessRunner(baseEnvironment: Self.environment)
  private(set) var planBase = ""
  private(set) var contract = ""
  private(set) var firstMerge = ""
  private(set) var secondMerge = ""

  init(root: URL) async throws {
    self.root = root
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try await git("init", "-q", "-b", "main")
    try await git("config", "commit.gpgsign", "false")
    try write("Aidoku/Features/Manga/MangaView.swift", "struct MangaView {}\n")
    planBase = try await commit("base")
    try write("Aidoku/Core/Downloads/Settings.swift", "enum DownloadSettings {}\n")
    contract = try await commit("contract")

    try await git("checkout", "-q", "-b", "download-check")
    try write(
      "Aidoku/Core/Downloads/LargeDownloadConfirmation.swift", "enum LargeDownloadConfirmation {}\n"
    )
    try write(
      Self.test, "import XCTest\nfinal class LargeDownloadConfirmationTests: XCTestCase {}\n")
    _ = try await commit("check")
    try await git("checkout", "-q", "main")
    try await git("merge", "-q", "--no-ff", "-m", "merge check", "download-check")
    firstMerge = try await git("rev-parse", "HEAD")

    try await git("checkout", "-q", "-b", "download-prompt", contract)
    try write("Aidoku/Features/Manga/MangaView.swift", "struct MangaView { var pending = 0 }\n")
    _ = try await commit("prompt")
    try await git("checkout", "-q", "main")
    try await git("merge", "-q", "--no-ff", "-m", "merge prompt", "download-prompt")
    secondMerge = try await git("rev-parse", "HEAD")
  }

  var adapter: LiveGit { LiveGit(runner: runner, repositoryRoot: root.path) }

  @discardableResult
  func git(_ arguments: String...) async throws -> String {
    let output = try await runner.run(
      ProcessInvocation(
        executable: "git", arguments: arguments, workingDirectory: root.path,
        timeout: .seconds(30)))
    guard output.status.isSuccess else {
      throw TrialGitFailure(arguments: arguments, stderr: output.stderr.text)
    }
    return output.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func write(_ path: String, _ content: String) throws {
    let url = root.appending(path: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(content.utf8).write(to: url)
  }

  private func commit(_ message: String) async throws -> String {
    try await git("add", "-A")
    try await git("commit", "-q", "-m", message)
    return try await git("rev-parse", "HEAD")
  }
}

private struct TrialGitFailure: Error {
  let arguments: [String]
  let stderr: String
}

extension BrownfieldMergeCheckTests {
  /// The trial's captured config, its area build-only, run at `revision` of `branch`.
  private static func trialRun(
    _ clone: Clone, _ branch: TrialPlanBranch, tier: CheckTier, at revision: String
  ) async throws -> (parts: GateRunParts, proofs: [ProvedTest], scratchRuns: Int) {
    try await branch.git("checkout", "-q", "--detach", revision)
    let state = clone.layout.commonDir.appending(
      path: StateRootResolver.commonConfigFile, directoryHint: .notDirectory)
    try FileManager.default.createDirectory(
      at: state.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(try Fixture.text("BrownfieldTrial/aidoku-validation-config.toml").utf8)
      .write(to: state)
    guard
      case .brownfield(let config)? = try ConfigLoader().loadProfile(
        repositoryRoot: clone.root, commonDir: clone.layout.commonDir)
    else {
      Issue.record("the trial's config didn't load as brownfield")
      return (GateRunParts(tiers: [], findings: []), [], 0)
    }
    // The area's root is `.`, so prove runs in the scratch tree's own directory, with no trailing
    // slash for ``Clone/inScratch(_:)`` to match.
    let reverted: @Sendable (AreaCommandRequest) -> Bool = { request in
      URL(filePath: request.workingDirectory, directoryHint: .isDirectory)
        .path(percentEncoded: false).hasPrefix(clone.scratch.path(percentEncoded: false))
    }
    let runner = FakeAreaCommandRunner { request in
      reverted(request) ? .failed(exit: 65, tail: "reverted", junit: nil) : .passed
    }
    let scratch = FakeScratchWorktrees(root: clone.scratch)
    let git = branch.adapter
    let dependencies = BrownfieldMergeCheck.Dependencies(
      config: config, layout: clone.layout, git: git, runner: runner,
      baseline: BaselineStore(layout: clone.layout, runner: runner, scratch: scratch),
      prove: BrownfieldProve.Dependencies(
        git: git, scratch: scratch, runner: runner, deadline: .seconds(5)),
      trackedTree: TrackedTreeSnapshot(files: [:]), tree: { _ in "tree0" },
      sliceBuildsOnly: { _ in true }, deadline: .seconds(5))
    let context = GateRun.Context(runID: "run", directory: clone.base)
    let parts = try await BrownfieldMergeCheck.run(
      root: clone.root, tier: tier, base: branch.planBase, context: context,
      dependencies: dependencies)
    return (parts, context.proofs.results, runner.requests.filter(reverted).count)
  }

  @Test(
    "a later merge gate proves only the tests its own merge brought, measured from the merge's first parent, while the first merge, final and a head that isn't a merge measure from the plan base — catches a second merge counting the first task's already-merged test as its own"
  )
  func mergeProvesFromTheFirstParent() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let branch = try await TrialPlanBranch(root: clone.root)

    let second = try await Self.trialRun(clone, branch, tier: .merge, at: branch.secondMerge)
    #expect(second.proofs == [], "the second merge changed no test")
    #expect(second.scratchRuns == 0)
    let summaries = second.parts.findings.filter { $0.ruleID == "prove.summary" }.map(\.message)
    #expect(
      summaries.contains { $0.hasPrefix("prove: no new or changed tests in Aidoku since") },
      "\(summaries)")

    let first = try await Self.trialRun(clone, branch, tier: .merge, at: branch.firstMerge)
    #expect(
      first.proofs
        == [
          ProvedTest(
            test: TrialPlanBranch.test, target: "Aidoku", outcome: .proven,
            proofBase: branch.planBase, assertion: nil)
        ], "the first merge measures from the plan base, so it takes in the contract's changes")

    let fixer = try await Self.trialRun(clone, branch, tier: .merge, at: "download-check")
    #expect(
      fixer.proofs.map(\.proofBase) == [branch.planBase],
      "a fix worktree's head is no merge, so its gate keeps the plan base")

    let final = try await Self.trialRun(clone, branch, tier: .final, at: branch.secondMerge)
    #expect(
      final.proofs
        == [
          ProvedTest(
            test: TrialPlanBranch.test, target: "Aidoku", outcome: .proven,
            proofBase: branch.planBase, assertion: nil)
        ])
  }
}

extension BrownfieldMergeCheckTests {
  @Test(
    "the trial's xcode area runs its merge steps in the checkout's own DerivedData — catches a merge gate building in Xcode's path-keyed default, away from the seed the warm-up filled"
  )
  func xcodeMergeStepsUseTheCheckoutDerivedData() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let config = try TOMLConfigDecoder().decodeBrownfield(
      try Fixture.text("BrownfieldTrial/aidoku-validation-config.toml"))
    let aidoku = try #require(config.areas.first)
    let runner = FakeAreaCommandRunner { _ in .passed }

    _ = try await Self.run(
      clone, tier: .merge, areas: [aidoku],
      changed: ["Aidoku/Shared/Managers/DownloadManager.swift"], runner: runner)

    let path = XcodeDerivedData.path(area: "Aidoku", layout: clone.layout)
    let head = runner.requests.filter {
      !clone.inScratch($0) && ($0.step == .build || $0.step == .test)
    }
    #expect(Set(head.map(\.step)) == [.build, .test])
    #expect(
      head.allSatisfy { $0.command.hasPrefix("xcodebuild -derivedDataPath '\(path)' ") },
      "\(head.map(\.command))")
  }
}

extension BrownfieldMergeCheckTests {
  @Test(
    "the send-money merge that brought AppFeature's reducer tests says merge proves only the build-only area and that slice proved AppFeature's tests, not that the merge has no new tests — catches a merge line that reads as if the merge added no tests"
  )
  func mergeSaysWhichAreasSliceProved() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let config = try TOMLConfigDecoder().decodeBrownfield(
      try Fixture.text("BrownfieldTrial/send-money-3-config.toml"))

    let parts = try await Self.run(
      clone, tier: .merge, areas: config.areas,
      changed: [
        "Packages/AppFeature/Sources/AppCore/AmountFeature.swift",
        "Packages/AppFeature/Sources/AppCore/ConfirmFeature.swift",
        "Packages/AppFeature/Sources/AppCore/SendMoneyFeature.swift",
        "Packages/AppFeature/Tests/AppCoreTests/SendMoneyFeatureTests.swift",
      ],
      runner: FakeAreaCommandRunner { _ in .passed }, buildsOnly: { !$0.selectsChangedTests })

    let summaries = parts.findings.filter { $0.ruleID == ProofRules.summaryRuleID }.map(\.message)
    #expect(
      !summaries.contains { $0.hasPrefix("prove: no new or changed tests since") },
      "\(summaries)")
    #expect(
      summaries.contains { $0.contains("AppFeature") && $0.contains("slice") }, "\(summaries)")
  }
}

/// Area step passes kept in memory for 1 test.
private final class MemoryAreaSteps: AreaStepReusing {
  private let passes = Mutex<[String: AreaStepPass]>([:])

  func pass(_ key: String) -> AreaStepPass? { passes.withLock { $0[key] } }

  func record(_ pass: AreaStepPass, key: String) { passes.withLock { $0[key] = pass } }
}

/// send-money-4's plan branch, rebuilt in a real repository from its captured UI test: a contract
/// commit that changes the app target's UI test and a view, then 2 task branches merged with
/// `--no-ff`, the first adding a package test with its source and the second only a view.
private struct SendMoneyPlanBranch {
  static let uiTest = "UITests/LaunchFlowUITests.swift"
  static let view = "Packages/AppFeature/Sources/AppUI/AppView.swift"

  let repository: TrialPlanBranch.Repository
  private(set) var planBase = ""
  private(set) var contract = ""
  private(set) var firstMerge = ""
  private(set) var secondMerge = ""

  init(root: URL) async throws {
    repository = try await TrialPlanBranch.Repository(root: root)
    try repository.write(
      Self.uiTest, try Fixture.text("BrownfieldTrial/send-money-4-LaunchFlowUITests-base.swift"))
    try repository.write(Self.view, "struct AppView {}\n")
    planBase = try await repository.commit("base")
    try repository.write(
      Self.uiTest,
      try Fixture.text("BrownfieldTrial/send-money-4-LaunchFlowUITests-contract.swift"))
    try repository.write(Self.view, "struct AppView { var title = \"\" }\n")
    contract = try await repository.commit("contract")

    try await repository.git("checkout", "-q", "-b", "account-client")
    try repository.write(
      "Packages/AppFeature/Sources/AccountClient/InMemoryAccountClient.swift",
      "struct InMemoryAccountClient {}\n")
    try repository.write(
      "Packages/AppFeature/Tests/AccountClientTests/AccountClientTests.swift",
      "import Testing\n@Test func startsAtBalance() {}\n")
    _ = try await repository.commit("account")
    try await repository.git("checkout", "-q", "main")
    try await repository.git("merge", "-q", "--no-ff", "-m", "merge account", "account-client")
    firstMerge = try await repository.git("rev-parse", "HEAD")

    try await repository.git("checkout", "-q", "-b", "send-flow-ui", contract)
    try repository.write(Self.view, "struct AppView { var title = \"Send\" }\n")
    _ = try await repository.commit("views")
    try await repository.git("checkout", "-q", "main")
    try await repository.git("merge", "-q", "--no-ff", "-m", "merge views", "send-flow-ui")
    secondMerge = try await repository.git("rev-parse", "HEAD")
  }
}

extension TrialPlanBranch {
  /// A scratch git repository the trial plan branches are rebuilt in.
  struct Repository {
    let root: URL
    let runner = LiveProcessRunner(baseEnvironment: TrialPlanBranch.environment)

    init(root: URL) async throws {
      self.root = root
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      try await git("init", "-q", "-b", "main")
      try await git("config", "commit.gpgsign", "false")
    }

    var adapter: LiveGit { LiveGit(runner: runner, repositoryRoot: root.path) }

    @discardableResult
    func git(_ arguments: String...) async throws -> String {
      let output = try await runner.run(
        ProcessInvocation(
          executable: "git", arguments: arguments, workingDirectory: root.path,
          timeout: .seconds(30)))
      guard output.status.isSuccess else {
        throw TrialGitFailure(arguments: arguments, stderr: output.stderr.text)
      }
      return output.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func write(_ path: String, _ content: String) throws {
      let url = root.appending(path: path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(content.utf8).write(to: url)
    }

    func commit(_ message: String) async throws -> String {
      try await git("add", "-A")
      try await git("commit", "-q", "-m", message)
      return try await git("rev-parse", "HEAD")
    }
  }
}

extension BrownfieldMergeCheckTests {
  /// send-money's captured config, whose app target only builds at slice, run at `revision`.
  private static func sendMoneyRun(
    _ clone: Clone, _ branch: SendMoneyPlanBranch, tier: CheckTier, at revision: String,
    bound: (@Sendable (String, AreaStep, AreaCommandTree) -> AreaCommandBound)? = nil,
    proveReuse: BrownfieldProve.ProveReuse? = nil, context: GateRun.Context? = nil
  ) async throws -> (parts: GateRunParts, proofs: [ProvedTest], scratchRuns: Int) {
    try await branch.repository.git("checkout", "-q", "--detach", revision)
    let config = try TOMLConfigDecoder().decodeBrownfield(
      try Fixture.text("BrownfieldTrial/send-money-3-config.toml"))
    let reverted: @Sendable (AreaCommandRequest) -> Bool = { request in
      URL(filePath: request.workingDirectory, directoryHint: .isDirectory)
        .path(percentEncoded: false).hasPrefix(clone.scratch.path(percentEncoded: false))
    }
    let runner = FakeAreaCommandRunner { request in
      reverted(request) ? .failed(exit: 65, tail: "reverted", junit: nil) : .passed
    }
    let scratch = FakeScratchWorktrees(root: clone.scratch)
    let git = branch.repository.adapter
    var scratchBound: (@Sendable (String, AreaStep) -> AreaCommandBound)?
    if let bound {
      scratchBound = { area, step in bound(area, step, .scratch) }
    }
    var prove = BrownfieldProve.Dependencies(
      git: git, scratch: scratch, runner: runner, deadline: .seconds(5), bound: scratchBound)
    prove.reuse = proveReuse
    let dependencies = BrownfieldMergeCheck.Dependencies(
      config: config, layout: clone.layout, git: git, runner: runner,
      baseline: BaselineStore(layout: clone.layout, runner: runner, scratch: scratch),
      prove: prove, trackedTree: TrackedTreeSnapshot(files: [:]), tree: { _ in "tree0" },
      sliceBuildsOnly: { !$0.selectsChangedTests }, deadline: .seconds(5), bound: bound)
    let context = context ?? GateRun.Context(runID: "run", directory: clone.base)
    let parts = try await BrownfieldMergeCheck.run(
      root: clone.root, tier: tier, base: branch.planBase, context: context,
      dependencies: dependencies)
    return (parts, context.proofs.results, runner.requests.filter(reverted).count)
  }

  @Test(
    "send-money-4's first merge proves the UI test the contract changed in its build-only app target, measured from the plan base, and the second merge doesn't prove it again — catches a contract's build-only test change no gate proves before final"
  )
  func firstMergeProvesTheContractsBuildOnlyTests() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let branch = try await SendMoneyPlanBranch(root: clone.root)

    let first = try await Self.sendMoneyRun(clone, branch, tier: .merge, at: branch.firstMerge)
    let app = first.proofs.filter { $0.target == "TimedBuildStarter" }
    #expect(!app.isEmpty, "\(first.parts.findings.map(\.message))")
    #expect(app.allSatisfy { $0.proofBase == branch.planBase && $0.outcome == .proven })

    let second = try await Self.sendMoneyRun(clone, branch, tier: .merge, at: branch.secondMerge)
    #expect(second.proofs.filter { $0.target == "TimedBuildStarter" } == [])
  }

  @Test(
    "send-money-4's final, whose box left 96 s for the app target's measured 226 s prove while every area's tests passed, is GREEN with a prove.unproven note where the trial read BLOCKED — catches a final blocked by a prove there was no time to run"
  )
  func finalWithNoTimeToProveIsUnprovenNotBlocked() async throws {
    let trial =
      try JSONSerialization.jsonObject(
        with: try Fixture.data("BrownfieldTrial/send-money-4-final.json")) as? [String: Any]
    let trialFindings = trial?["findings"] as? [[String: Any]] ?? []
    let skipped = try #require(trialFindings.first { $0["rule"] as? String == "prove.no-evidence" })
    #expect(trial?["verdict"] as? String == "BLOCKED")
    let reason = "the 96 s left before the run's box ends at 2026-10-05T06:33:02Z"
    #expect((skipped["message"] as? String)?.contains(reason) == true)

    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let branch = try await SendMoneyPlanBranch(root: clone.root)
    let short: @Sendable (String, AreaStep, AreaCommandTree) -> AreaCommandBound = {
      _, _, tree in
      tree == .scratch
        ? AreaCommandBound(duration: .seconds(96), reason: reason, expected: .seconds(226))
        : AreaCommandBound(duration: .seconds(600), reason: "the floor")
    }

    let final = try await Self.sendMoneyRun(
      clone, branch, tier: .final, at: branch.secondMerge, bound: short)

    #expect(Self.verdict(final.parts) == .green)
    let unproven = final.parts.findings.filter { $0.ruleID == ProofRules.unprovenRuleID }
    #expect(unproven.count == 1)
    #expect(unproven.allSatisfy { $0.severity == .nit && $0.message.contains("TimedBuildStarter") })
    #expect(unproven.first?.message.contains(reason) == true)
    #expect(!final.parts.findings.contains { $0.ruleID == ProofRules.noEvidenceRuleID })

    let merge = try await Self.sendMoneyRun(
      clone, branch, tier: .merge, at: branch.firstMerge, bound: short)
    #expect(
      Self.verdict(merge.parts) == .blocked, "a merge gate still blocks: a later gate can prove")
  }
}

/// Prove passes kept in memory for 1 test.
private final class MemoryProves: ProveReusing {
  private let passes = Mutex<[String: ProvePass]>([:])

  func pass(_ key: String) -> ProvePass? { passes.withLock { $0[key] } }

  func record(_ pass: ProvePass, key: String) { passes.withLock { $0[key] = pass } }
}

extension BrownfieldMergeCheckTests {
  /// Reuse for 1 gate run of `tier` over the plan branch, every input but the head tree shared.
  /// - Parameter treeHash: the head's tree; `nil` names a tree no other run shares.
  private static func proveReuse(
    _ branch: SendMoneyPlanBranch, store: MemoryProves, runID: String, tier: CheckTier,
    treeHash: String? = nil
  ) -> BrownfieldProve.ProveReuse {
    let repository = branch.repository
    return BrownfieldProve.ProveReuse(
      inputs: GateReuse.Inputs(
        tier: tier, treeHash: treeHash ?? "head-\(runID)", mergeBase: branch.planBase,
        sourceHash: "bin1",
        stateFiles: ["config": "c1"]),
      store: store, runID: runID, tier: tier,
      renames: { since in
        await GitRenames.between(
          since, "HEAD", runner: repository.runner, directory: repository.root.path)
      })
  }

  @Test(
    "as in send-money-7, where the first merge gate proved the launch UI test in 96 s and final proved it again in 85 s on the same reverted tree, final takes the merge's proof without a reverted run, records its prove.result again and names the merge run, and its prove step reads reused — catches final re-proving a test nothing has changed since its merge proved it"
  )
  func finalTakesTheMergesProveOnTheSameRevertedTree() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let branch = try await SendMoneyPlanBranch(root: clone.root)
    let store = MemoryProves()

    let merge = try await Self.sendMoneyRun(
      clone, branch, tier: .merge, at: branch.firstMerge,
      proveReuse: Self.proveReuse(branch, store: store, runID: "merge-run", tier: .merge))
    #expect(merge.scratchRuns > 0)
    let proved = merge.proofs.filter { $0.target == "TimedBuildStarter" }
    #expect(!proved.isEmpty && proved.allSatisfy { $0.outcome == .proven })

    let context = GateRun.Context(runID: "final-run", directory: clone.base)
    let final = try await Self.sendMoneyRun(
      clone, branch, tier: .final, at: branch.secondMerge,
      proveReuse: Self.proveReuse(branch, store: store, runID: "final-run", tier: .final),
      context: context)

    #expect(final.scratchRuns == 0, "final ran no reverted run")
    #expect(final.proofs == proved)
    #expect(Self.verdict(final.parts) == .green)
    let reused = final.parts.findings.filter {
      $0.ruleID == GateReuse.ruleID && $0.message.contains("merge-run")
    }
    #expect(reused.count == 1, "\(final.parts.findings.map(\.message))")
    let step = try #require(context.steps.steps.first { $0.step == .prove })
    #expect(step.derivedData == .reused)
  }

  @Test(
    "final runs the prove again when the UI test changed after the merge proved it, or when a later merge renamed a source file the reverted tree puts back — catches a reused proof standing in for a tree prove would build differently"
  )
  func finalProvesAgainWhenTheRevertedTreeDiffers() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let branch = try await SendMoneyPlanBranch(root: clone.root)
    let store = MemoryProves()
    _ = try await Self.sendMoneyRun(
      clone, branch, tier: .merge, at: branch.firstMerge,
      proveReuse: Self.proveReuse(branch, store: store, runID: "merge-run", tier: .merge))

    let repository = branch.repository
    try await repository.git("checkout", "-q", "main")
    // Back to its plan-base text first, so git reads the move as a rename since the plan base.
    try repository.write(SendMoneyPlanBranch.view, "struct AppView {}\n")
    try await repository.git(
      "mv", SendMoneyPlanBranch.view, "Packages/AppFeature/Sources/AppUI/HomeView.swift")
    let renamed = try await repository.commit("rename the view")
    let afterRename = try await Self.sendMoneyRun(
      clone, branch, tier: .final, at: renamed,
      proveReuse: Self.proveReuse(branch, store: store, runID: "final-1", tier: .final))
    #expect(afterRename.scratchRuns > 0, "a rename changes the reverted tree")

    try await repository.git("checkout", "-q", "main")
    let uiTest = repository.root.appending(path: SendMoneyPlanBranch.uiTest)
    let edited = try String(contentsOf: uiTest, encoding: .utf8) + "\nfinal class More {}\n"
    try repository.write(SendMoneyPlanBranch.uiTest, edited)
    let changed = try await repository.commit("edit the UI test")
    let afterEdit = try await Self.sendMoneyRun(
      clone, branch, tier: .final, at: changed,
      proveReuse: Self.proveReuse(branch, store: store, runID: "final-2", tier: .final))
    #expect(afterEdit.scratchRuns > 0, "a changed test changes the reverted tree")
  }
}

extension BrownfieldMergeCheckTests {
  @Test(
    "a merge gate on a clean tree records each area step it passed as that tree's baseline answer, which a gate measuring from the merge then finds without a rerun — catches each task cut from a merge rerunning at its merge base a step the merge gate passed there"
  )
  func mergePassesAnswerTheBaselineAtTheirTree() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let config = try TOMLConfigDecoder().decodeBrownfield(
      try Fixture.text("BrownfieldTrial/send-money-7-config.toml"))
    let changed = ["Packages/AppFeature/Sources/AppCore/AppFeature.swift"]

    _ = try await Self.run(
      clone, tier: .merge, areas: config.areas, changed: changed,
      runner: FakeAreaCommandRunner { _ in .passed }, headTree: "tree0")

    let results = BaselineStore(
      layout: clone.layout, runner: FakeAreaCommandRunner { _ in .passed },
      scratch: FakeScratchWorktrees(root: clone.scratch)
    ).load(tree: "tree0").results
    let app = try #require(config.areas.first { $0.name == "AppFeature" })
    #expect(
      results[BaselineStepKey(area: "AppFeature", step: .build, command: try #require(app.build))]
        == .passed, "\(results)")

    let broken = FakeAreaCommandRunner { request in
      request.area == "AppFeature" && request.step == .build && !clone.inScratch(request)
        ? .failed(exit: 1, tail: "error: no such module 'AccountClient'", junit: nil) : .passed
    }
    let parts = try await Self.run(
      clone, tier: .merge, areas: config.areas, changed: changed, runner: broken)
    #expect(!broken.requests.contains { clone.inScratch($0) && $0.step == .build })
    #expect(Self.gating(parts).contains("area.build-failed Packages/AppFeature"))
  }
}

extension SendMoneyPlanBranch {
  /// A last task cut from the plan branch's tip that edits the UI test and the view, merged with
  /// `--no-ff`, so its merge gate proves from the tip before it while final proves from the plan
  /// base. With `otherUITest`, a commit on the plan branch first adds a second UI test that the
  /// last task leaves alone.
  func lastMerge(otherUITest: Bool = false) async throws -> String {
    try await repository.git("checkout", "-q", "main")
    if otherUITest {
      try repository.write(
        "UITests/SendFlowUITests.swift",
        "import XCTest\n\nfinal class SendFlowUITests: XCTestCase {\n"
          + "  func testSend() { XCTAssertTrue(true) }\n}\n")
      _ = try await repository.commit("another UI test")
    }
    try await repository.git("checkout", "-q", "-b", "last-task")
    let uiTest = repository.root.appending(path: Self.uiTest)
    try repository.write(
      Self.uiTest, try String(contentsOf: uiTest, encoding: .utf8) + "\nfinal class More {}\n")
    try repository.write(Self.view, "struct AppView { var title = \"Sent\" }\n")
    _ = try await repository.commit("last task")
    try await repository.git("checkout", "-q", "main")
    try await repository.git("merge", "-q", "--no-ff", "-m", "merge last task", "last-task")
    return try await repository.git("rev-parse", "HEAD")
  }

  func tree(_ revision: String) async throws -> String {
    try await repository.git("rev-parse", "\(revision)^{tree}")
  }
}

extension BrownfieldMergeCheckTests {
  @Test(
    "as in a trial whose last merge gate proved the launch UI test in 85 s from the merge's first parent and whose final proved it again in 77 s from the plan base on the same head tree, final takes the merge's proof with no reverted run, names the merge run and keeps the merge's proof base — catches final re-proving a head its last merge just proved"
  )
  func finalTakesTheLastMergesProveAtTheSameHead() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let branch = try await SendMoneyPlanBranch(root: clone.root)
    let head = try await branch.lastMerge()
    let tree = try await branch.tree(head)
    let store = MemoryProves()

    let merge = try await Self.sendMoneyRun(
      clone, branch, tier: .merge, at: head,
      proveReuse: Self.proveReuse(
        branch, store: store, runID: "merge-run", tier: .merge, treeHash: tree))
    #expect(merge.scratchRuns > 0)
    let proved = merge.proofs.filter { $0.target == "TimedBuildStarter" }
    #expect(!proved.isEmpty && proved.allSatisfy { $0.outcome == .proven })
    #expect(proved.allSatisfy { $0.proofBase == branch.secondMerge })

    let context = GateRun.Context(runID: "final-run", directory: clone.base)
    let final = try await Self.sendMoneyRun(
      clone, branch, tier: .final, at: head,
      proveReuse: Self.proveReuse(
        branch, store: store, runID: "final-run", tier: .final, treeHash: tree),
      context: context)

    #expect(final.scratchRuns == 0, "final ran no reverted run")
    #expect(final.proofs == proved)
    #expect(Self.verdict(final.parts) == .green)
    let reused = final.parts.findings.filter {
      $0.ruleID == GateReuse.ruleID && $0.message.contains("merge-run")
        && $0.message.contains("same head tree")
    }
    #expect(reused.count == 1, "\(final.parts.findings.map(\.message))")
    let step = try #require(context.steps.steps.first { $0.step == .prove })
    #expect(step.derivedData == .reused)
  }

  @Test(
    "final proves again when its head tree differs from the merge's, or when it measures a changed UI test the merge didn't run though the head tree is the merge's — catches a head credit standing in for different code or for a test no gate proved"
  )
  func finalProvesAgainWhenTheHeadOrItsTestsDiffer() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let branch = try await SendMoneyPlanBranch(root: clone.root)
    let head = try await branch.lastMerge()
    let store = MemoryProves()
    _ = try await Self.sendMoneyRun(
      clone, branch, tier: .merge, at: head,
      proveReuse: Self.proveReuse(
        branch, store: store, runID: "merge-run", tier: .merge,
        treeHash: try await branch.tree(head)))

    let repository = branch.repository
    try await repository.git("checkout", "-q", "main")
    try repository.write(SendMoneyPlanBranch.view, "struct AppView { var title = \"Done\" }\n")
    let later = try await repository.commit("edit the view")
    let afterEdit = try await Self.sendMoneyRun(
      clone, branch, tier: .final, at: later,
      proveReuse: Self.proveReuse(
        branch, store: store, runID: "final-1", tier: .final,
        treeHash: try await branch.tree(later)))
    #expect(afterEdit.scratchRuns > 0, "another head tree is other code under test")

    let other = try Clone()
    defer { try? FileManager.default.removeItem(at: other.base) }
    let otherBranch = try await SendMoneyPlanBranch(root: other.root)
    let otherHead = try await otherBranch.lastMerge(otherUITest: true)
    let otherTree = try await otherBranch.tree(otherHead)
    let otherStore = MemoryProves()
    let otherMerge = try await Self.sendMoneyRun(
      other, otherBranch, tier: .merge, at: otherHead,
      proveReuse: Self.proveReuse(
        otherBranch, store: otherStore, runID: "merge-run", tier: .merge, treeHash: otherTree))
    #expect(otherMerge.scratchRuns > 0)
    let otherFinal = try await Self.sendMoneyRun(
      other, otherBranch, tier: .final, at: otherHead,
      proveReuse: Self.proveReuse(
        otherBranch, store: otherStore, runID: "final-2", tier: .final, treeHash: otherTree))
    #expect(otherFinal.scratchRuns > 0, "final's changed tests hold one the merge didn't run")
    #expect(otherFinal.proofs.contains { $0.test.contains("SendFlowUITests") })
  }
}

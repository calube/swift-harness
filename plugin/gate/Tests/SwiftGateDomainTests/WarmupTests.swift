import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

private let layout = BrownfieldStateLayout(
  commonDir: URL(filePath: "/clone/.git", directoryHint: .isDirectory),
  gitDir: URL(filePath: "/clone/.git", directoryHint: .isDirectory))

private func area(
  _ name: String, kind: AreaKind = .node, build: String? = "npm run build",
  test: String? = "npm test", xcode: XcodeAreaConfig? = nil
) -> BrownfieldArea {
  BrownfieldArea(
    name: name, root: "packages/\(name)", language: .typescript, kind: kind, test: test,
    testFiles: nil, lint: nil, build: build, e2e: nil, testGlobs: [], packs: [], xcode: xcode)
}

private let xcodegenConfig = XcodeAreaConfig(
  workspace: nil, project: "App/App.xcodeproj", inclusion: .xcodegen, manifest: "App/project.yml",
  schemes: ["App"])

/// Counts arrivals, and lets a caller wait for a number of them with no bound of its own: a
/// deadline here would lose to a loaded machine that starts the last arrival late. A wait that
/// never ends is a regression the suite's time limit ends by cancelling it.
private final class Arrivals: Sendable {
  private struct State {
    var arrived = 0
    var waiting: [UUID: (count: Int, continuation: CheckedContinuation<Void, Never>)] = [:]
  }

  private let state = Mutex(State())

  func arrive() {
    let released = state.withLock { state in
      state.arrived += 1
      let ready = state.waiting.filter { $0.value.count <= state.arrived }
      for id in ready.keys { state.waiting[id] = nil }
      return ready.values.map(\.continuation)
    }
    for continuation in released { continuation.resume() }
  }

  /// Whether `count` have arrived, once they have or the wait is cancelled.
  func reached(_ count: Int) async -> Bool {
    let id = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let done = state.withLock { state in
          if state.arrived >= count || Task.isCancelled { return true }
          state.waiting[id] = (count, continuation)
          return false
        }
        if done { continuation.resume() }
      }
    } onCancel: {
      state.withLock { $0.waiting.removeValue(forKey: id) }?.continuation.resume()
    }
    return state.withLock { $0.arrived >= count }
  }
}

/// Takes `duration` of wall time without a real sleep: a fake command's own run time.
private func spin(for duration: Duration) async {
  let end = ContinuousClock.now + duration
  while ContinuousClock.now < end { await Task.yield() }
}

/// Records every request and every finished area.
private final class Recorder: Sendable {
  let requests = Mutex<[AreaCommandRequest]>([])
  let finished = Mutex<[String]>([])
  let generated = Mutex<[String]>([])
}

private func dependencies(
  known: WarmupTimesFile = WarmupTimesFile(tree: "t1"), recorder: Recorder = Recorder(),
  tree: TrackedTreeSnapshot = TrackedTreeSnapshot(files: [:]),
  run: @escaping @Sendable (AreaCommandRequest) async -> AreaCommandOutcome = { _ in .passed },
  generation:
    @escaping @Sendable (_ body: @Sendable (String) async -> WarmupTreeRun) async ->
    WarmupGeneration = { body in .generated(milliseconds: 7, run: await body("/scratch/tree")) }
) -> Warmup.Dependencies {
  Warmup.Dependencies(
    layout: layout, repositoryRoot: "/clone", trackedTree: tree, known: known,
    deadline: .seconds(60),
    run: { request in
      recorder.requests.withLock { $0.append(request) }
      return await run(request)
    },
    generate: { area, body in
      recorder.generated.withLock { $0.append(area.name) }
      return await generation(body)
    },
    finished: { result in recorder.finished.withLock { $0.append(result.area) } })
}

private func outcomes(_ result: WarmupAreaResult) -> [WarmupStep: WarmupOutcome] {
  Dictionary(uniqueKeysWithValues: result.steps.map { ($0.step, $0.outcome) })
}

@Suite("Warm-up", .timeLimit(.minutes(5)))
struct WarmupTests {
  @Test("3 areas' builds start together — catches a serial warm-up")
  func areasStartTogether() async {
    let counter = Arrivals()
    let met = Mutex<[Bool]>([])

    let results = await Warmup.run(
      areas: [area("web"), area("api"), area("docs")],
      dependencies: dependencies { request in
        if request.step == .build {
          counter.arrive()
          let together = await counter.reached(3)
          met.withLock { $0.append(together) }
        }
        return .passed
      })

    #expect(met.withLock { $0 } == [true, true, true])
    #expect(results.map(\.area) == ["web", "api", "docs"])
  }

  @Test(
    "a failing guessed command records failed and every other area finishes — catches 1 failure stopping the warm-up"
  )
  func failureDoesNotStopOthers() async {
    let recorder = Recorder()
    let results = await Warmup.run(
      areas: [area("web"), area("api"), area("docs")],
      dependencies: dependencies(recorder: recorder) { request in
        request.area == "web" && request.step == .build
          ? .failed(exit: 1, tail: "npm ERR! missing script: build", junit: nil) : .passed
      })

    let byArea = Dictionary(uniqueKeysWithValues: results.map { ($0.area, $0) })
    #expect(byArea["web"].map(outcomes) == [.build: .failed, .test: .passed])
    #expect(byArea["web"]?.steps.first?.detail == "npm ERR! missing script: build")
    #expect(byArea["api"].map(outcomes) == [.build: .passed, .test: .passed])
    #expect(byArea["docs"].map(outcomes) == [.build: .passed, .test: .passed])
    #expect(recorder.finished.withLock { $0 }.sorted() == ["api", "docs", "web"])
  }

  @Test("build runs before test in each area — catches a test that runs on a cold build")
  func buildThenTest() async {
    let recorder = Recorder()
    _ = await Warmup.run(area: area("web"), dependencies: dependencies(recorder: recorder))
    #expect(recorder.requests.withLock { $0 }.map(\.step) == [.build, .test])
  }

  @Test(
    "a step with no command is dropped and the area's other steps still run — catches a missing build skipping the tests"
  )
  func missingStepIsDropped() async {
    let recorder = Recorder()
    let result = await Warmup.run(
      area: area("web", build: nil), dependencies: dependencies(recorder: recorder))

    #expect(outcomes(result) == [.build: .dropped, .test: .passed])
    #expect(recorder.requests.withLock { $0 }.map(\.step) == [.test])
    #expect(result.events.map(\.outcome) == [.dropped, .passed])
  }

  @Test(
    "a second warm-up on the same tree reads cache warm and keeps the first run's cold cost — catches every run reporting cold"
  )
  func secondRunIsWarm() async {
    let first = await Warmup.run(area: area("web"), dependencies: dependencies())
    #expect(first.steps.map(\.cache) == [.cold, .cold])

    var known = WarmupTimesFile(tree: "t1")
    let firstRecord = WarmupAreaRecord(
      coldMilliseconds: 99_999, testMilliseconds: first.record.testMilliseconds,
      steps: first.record.steps)
    known.merge(area: "web", record: firstRecord)
    let second = await Warmup.run(area: area("web"), dependencies: dependencies(known: known))

    #expect(second.steps.map(\.cache) == [.warm, .warm])
    #expect(second.record.coldMilliseconds == 99_999)
    #expect(second.events.map(\.cache) == [.warm, .warm])
  }

  @Test("the first run's cold cost and test time are recorded — catches a record with no times")
  func firstRunRecordsTimes() async throws {
    let result = await Warmup.run(
      area: area("web"),
      dependencies: dependencies { request in
        if request.step == .test { await spin(for: .milliseconds(30)) }
        return .passed
      })

    let test = try #require(result.record.testMilliseconds)
    #expect(test >= 30)
    #expect(result.record.coldMilliseconds >= test)
    #expect(result.record.steps == [.build: .passed, .test: .passed])
  }

  @Test(
    "a step whose tool isn't on PATH is not-installed, not failed — catches a missing tool read as the base tree failing"
  )
  func missingToolIsNotInstalled() async throws {
    let missing = try Fixture.areaRun("swift/lint-not-installed")
    let result = await Warmup.run(
      area: area("web"),
      dependencies: dependencies { request in request.step == .test ? missing : .passed })

    #expect(outcomes(result) == [.build: .passed, .test: .notInstalled])
    #expect(result.baseline.map(\.result) == [.passed, .notInstalled])
    #expect(result.record.warmTestMilliseconds == nil)
  }

  @Test(
    "a failed test step gives no warm test time, so slice builds — catches a 2 s failure read as a test run that fits the budget"
  )
  func failedTestGivesNoWarmTime() async throws {
    let result = await Warmup.run(
      area: area("web"),
      dependencies: dependencies { request in
        request.step == .test ? .failed(exit: 65, tail: "** TEST FAILED **", junit: nil) : .passed
      })

    #expect(outcomes(result) == [.build: .passed, .test: .failed])
    #expect(result.record.warmTestMilliseconds == nil)
    var file = WarmupTimesFile(tree: "t1")
    file.merge(area: "web", record: result.record)
    #expect(file.buildsOnly("web", budgetSeconds: 30))

    // An iOS brownfield trial's warm-up: build and test both failed on plugin validation, the
    // test in 2455 ms, and slice read that time as fitting the 30 s budget.
    let trial = WarmupAreaRecord(
      coldMilliseconds: 23_590, testMilliseconds: 2_455, steps: [.build: .failed, .test: .failed])
    #expect(trial.warmTestMilliseconds == nil)
    let passed = WarmupAreaRecord(
      coldMilliseconds: 8_112, testMilliseconds: 106_954,
      steps: [.build: .passed, .test: .passed])
    #expect(passed.warmTestMilliseconds == 106_954)
  }

  @Test(
    "the build and test answers are baseline records keyed as gates key them — catches a warm-up that fills no baseline"
  )
  func fillsTheBaseline() async {
    let result = await Warmup.run(
      area: area("web"),
      dependencies: dependencies { request in
        request.step == .test ? .failed(exit: 1, tail: "1 failed", junit: nil) : .passed
      })

    #expect(
      Set(result.baseline.map { "\($0.key.step.rawValue) \($0.key.command) \($0.result)" }) == [
        "build npm run build passed", "test npm test failed",
      ])
    #expect(result.baseline.allSatisfy { $0.key.area == "web" && $0.key.selection.isEmpty })
  }

  @Test(
    "each command gets the area's shared cache variables and a JUnit path under the git dir — catches a warm-up that fills no shared store"
  )
  func requestsCarryTheSharedCaches() async {
    let recorder = Recorder()
    _ = await Warmup.run(
      area: area("web", test: "npx jest --reporters=jest-junit --outputFile={junit}"),
      dependencies: dependencies(recorder: recorder))

    let requests = recorder.requests.withLock { $0 }
    let caches = AreaCacheEnvironment.cachesDirectory(layout: layout)
    #expect(requests.allSatisfy { $0.environment["npm_config_cache"] == "\(caches)/npm" })
    #expect(requests.allSatisfy { $0.workingDirectory == "/clone/packages/web" })
    #expect(requests.last?.junitPath?.hasPrefix("/clone/.git/") == true)
  }

  @Test(
    "an xcode area's build and test build in the area's seed with nothing to copy — catches a warm-up filling Xcode's path-keyed default DerivedData, which no task worktree reads"
  )
  func xcodeAreaBuildsInTheSeed() async {
    let recorder = Recorder()
    _ = await Warmup.run(
      area: area(
        "app", kind: .xcode, build: "xcodebuild build -scheme App",
        test: "xcodebuild test -scheme App"),
      dependencies: dependencies(recorder: recorder))

    let seed = AreaCacheEnvironment.derivedDataSeed(area: "app", layout: layout)
    #expect(
      recorder.requests.withLock { $0 }.map(\.command) == [
        "xcodebuild -derivedDataPath '\(seed)' build -scheme App",
        "xcodebuild -derivedDataPath '\(seed)' test -scheme App -resultBundlePath "
          + "'/clone/.git/swift-harness/junit/app.test.xcresult'",
      ])
    #expect(recorder.requests.withLock { $0 }.allSatisfy { $0.derivedDataSeed == nil })
  }

  @Test(
    "a swiftpm area's build and test build in the area's shared scratch path — catches a warm-up filling a .build no slot or prove tree reads, so the send-money trial's first prove built cold for 328 s"
  )
  func swiftPMAreaBuildsInTheSharedScratchPath() async {
    let recorder = Recorder()
    let package = area(
      "AppFeature", kind: .swiftpm, build: "swift build",
      test: "swift test --parallel --xunit-output {junit}")
    _ = await Warmup.run(area: package, dependencies: dependencies(recorder: recorder))
    let shared = ScratchTreeBuild.swiftPMScratchPath(area: "AppFeature", layout: layout)
    let commands = recorder.requests.withLock { $0 }.map(\.command)
    #expect(commands.count == 2)
    #expect(commands.allSatisfy { $0.contains(" --scratch-path '\(shared)'") }, "\(commands)")
  }

  @Test(
    "an xcode area's prove tree build is its test as build-for-testing in the tree, into the checkout's prove DerivedData — catches a checkout's first merge prove building cold in its kept tree"
  )
  func xcodeProveTreeBuildsForTesting() throws {
    let slot = BrownfieldStateLayout(
      commonDir: URL(filePath: "/clone/.git", directoryHint: .isDirectory),
      gitDir: URL(filePath: "/clone/.git/worktrees/checkout", directoryHint: .isDirectory))
    let app = area(
      "app", kind: .xcode, build: "xcodebuild build -scheme App",
      test: "xcodebuild test -scheme App -destination 'platform=iOS Simulator,name=iPhone 17'")

    let request = try #require(
      Warmup.proveTreeRequest(area: app, toplevel: "/tree", layout: slot, deadline: .seconds(9)))

    let prove = XcodeDerivedData.provePath(area: "app", layout: slot)
    #expect(
      request.command
        == "xcodebuild -derivedDataPath '\(prove)' build-for-testing -scheme App "
        + "-destination 'platform=iOS Simulator,name=iPhone 17'")
    #expect(request.workingDirectory == "/tree/packages/app")
    #expect(request.derivedDataSeed?.destination == prove)
    #expect(request.buildLock?.directory == prove)
    #expect(
      Warmup.proveTreeRequest(
        area: area("app", kind: .xcode, xcode: xcodegenConfig), toplevel: "/tree", layout: slot,
        deadline: .seconds(9)) == nil)
    #expect(
      Warmup.proveTreeRequest(
        area: area("web"), toplevel: "/tree", layout: slot, deadline: .seconds(9)) == nil)
  }

  @Test(
    "an XcodeGen area generates first and builds and tests in the generated tree — catches a build in the user's tree when the project is generated elsewhere"
  )
  func generatorAreaBuildsInItsTree() async {
    let recorder = Recorder()
    let result = await Warmup.run(
      area: area("app", kind: .xcode, xcode: xcodegenConfig),
      dependencies: dependencies(recorder: recorder))

    #expect(recorder.generated.withLock { $0 } == ["app"])
    #expect(result.steps.map(\.step) == [.generate, .build, .test])
    #expect(result.steps.first?.milliseconds == 7)
    #expect(
      recorder.requests.withLock { $0 }.allSatisfy {
        $0.workingDirectory == "/scratch/tree/packages/app"
      })
  }

  @Test(
    "a generator not on this machine records not-installed and runs no build — catches a build against a project that was never generated"
  )
  func missingGeneratorStopsTheArea() async {
    let recorder = Recorder()
    let result = await Warmup.run(
      area: area("app", kind: .xcode, xcode: xcodegenConfig),
      dependencies: dependencies(
        recorder: recorder,
        generation: { _ in
          .notGenerated(
            milliseconds: 3, outcome: .notInstalled, detail: "env: xcodegen: No such file")
        }))

    #expect(result.events.map(\.outcome) == [.notInstalled])
    #expect(result.steps.first?.detail == "env: xcodegen: No such file")
    #expect(recorder.requests.withLock { $0 }.isEmpty)
    #expect(recorder.finished.withLock { $0 } == ["app"])
    #expect(result.record.steps == [.generate: .notInstalled])
  }

  @Test("an area without a generator never generates — catches a generate step on every area")
  func plainAreaNeverGenerates() async {
    let recorder = Recorder()
    let result = await Warmup.run(area: area("web"), dependencies: dependencies(recorder: recorder))
    #expect(recorder.generated.withLock { $0 }.isEmpty)
    #expect(result.steps.map(\.step) == [.build, .test])
  }

  @Test("each step becomes 1 warmup.run naming its area, step and outcome — catches a lost event")
  func eventsPerStep() async {
    let result = await Warmup.run(
      area: area("web"),
      dependencies: dependencies { request in
        request.step == .test ? .timedOut(tail: "") : .passed
      })
    #expect(
      result.events.map { "\($0.area) \($0.step.rawValue) \($0.outcome.rawValue)" } == [
        "web build passed", "web test failed",
      ])
  }

  @Test(
    "the generated project counts as tracked only when a tracked path sits inside it — catches generating a committed project in place"
  )
  func generatedProjectTracked() {
    let tracked = TrackedTreeSnapshot(files: ["App/App.xcodeproj/project.pbxproj": Data()])
    let untracked = TrackedTreeSnapshot(files: ["App/project.yml": Data()])
    let lookalike = TrackedTreeSnapshot(files: ["App/App.xcodeprojects/x": Data()])
    #expect(Warmup.generatedProjectTracked(xcodegenConfig, tree: tracked))
    #expect(!Warmup.generatedProjectTracked(xcodegenConfig, tree: untracked))
    #expect(!Warmup.generatedProjectTracked(xcodegenConfig, tree: lookalike))
  }
}

@Suite("Warm-up times file")
struct WarmupTimesFileTests {
  private static func file() -> WarmupTimesFile {
    var file = WarmupTimesFile(tree: "t1")
    file.merge(
      area: "web",
      record: WarmupAreaRecord(
        coldMilliseconds: 61_000, testMilliseconds: 45_000,
        steps: [.build: .passed, .test: .passed]))
    file.merge(
      area: "api",
      record: WarmupAreaRecord(
        coldMilliseconds: 9_000, testMilliseconds: nil, steps: [.build: .passed, .test: .dropped]))
    return file
  }

  @Test("a file round-trips through encode and decode — catches a dropped area or step")
  func roundTrips() throws {
    let file = Self.file()
    #expect(file.areas.count == 2)
    #expect(try WarmupTimesFile.decode(file.encoded(), tree: "t1") == file)
  }

  @Test("an unknown step fails decoding naming it — catches an open step vocabulary")
  func unknownStepFails() {
    let data = Data(
      #"{"version":1,"tree":"t1","areas":{"web":{"coldMs":1,"steps":{"deploy":"passed"}}}}"#.utf8)
    #expect {
      _ = try WarmupTimesFile.decode(data, tree: "t1")
    } throws: { ($0 as? WarmupTimesFileError)?.detail.contains("deploy") == true }
  }

  @Test("a file recorded for another tree fails decoding — catches times from another base")
  func otherTreeFails() {
    #expect(throws: WarmupTimesFileError.self) {
      _ = try WarmupTimesFile.decode(Self.file().encoded(), tree: "t2")
    }
  }

  @Test(
    "an area builds only when its warm test time is over the slice budget or unmeasured — catches a 45 s test run inside slice"
  )
  func buildsOnly() {
    let file = Self.file()
    #expect(file.buildsOnly("web", budgetSeconds: 30))
    #expect(!file.buildsOnly("web", budgetSeconds: 60))
    #expect(file.buildsOnly("api", budgetSeconds: 30))
    #expect(file.buildsOnly("unknown", budgetSeconds: 30))
  }

  @Test("merging an area replaces only that area — catches a merge that drops other areas")
  func mergeReplacesOneArea() {
    var file = Self.file()
    let newer = WarmupAreaRecord(coldMilliseconds: 61_000, testMilliseconds: 12_000, steps: [:])
    file.merge(area: "web", record: newer)
    #expect(file.areas["web"] == newer)
    #expect(file.areas["api"]?.coldMilliseconds == 9_000)
  }
}

@Suite("Warm-up slot turns")
struct WarmupSlotTurnsTests {
  @Test(
    "the warm-up builds 1 task slot at a time, the qa slot right after the first, so a foreground gate in the plan checkout shares the machine with 1 slot's builds — catches every slot's builds started at once, which slowed a contract slice gate from 93 s to 240 s"
  )
  func oneSlotATime() {
    let turns = Warmup.slotTurns(tasks: ["/s1", "/s2", "/s3", "/s4"], qa: "/s5")

    #expect(
      turns == [.tasks(["/s1"]), .qa("/s5"), .tasks(["/s2"]), .tasks(["/s3"]), .tasks(["/s4"])])
  }
}

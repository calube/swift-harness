import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

@Suite("test-only: 1 test through an area's own command")
struct TestOnlyCheckTests {
  static let id = "AidokuTests/ConfirmLargeDownloadsSettingTests"

  /// The Aidoku trial's clone config under a temp common dir, and a run directory.
  private struct Clone {
    let base: URL
    var root: URL { base.appending(path: "repo", directoryHint: .isDirectory) }
    var run: URL { base.appending(path: "run", directoryHint: .isDirectory) }
    var layout: BrownfieldStateLayout {
      BrownfieldStateLayout(
        commonDir: base.appending(path: "common", directoryHint: .isDirectory),
        gitDir: base.appending(path: "gitdir", directoryHint: .isDirectory))
    }
    let config: String
    let areas: [BrownfieldArea]

    init() throws {
      base = TestTemporaryDirectory.root.appending(
        path: "swiftgate-test-only-\(UUID().uuidString)", directoryHint: .isDirectory)
      for directory in [base, base.appending(path: "repo"), base.appending(path: "run")] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      }
      config = try Fixture.text("BrownfieldTrial/aidoku-validation-config.toml")
      let layout = BrownfieldStateLayout(
        commonDir: base.appending(path: "common", directoryHint: .isDirectory),
        gitDir: base.appending(path: "gitdir", directoryHint: .isDirectory))
      let file = layout.commonDir.appending(path: StateRootResolver.commonConfigFile)
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(config.utf8).write(to: file)
      guard
        case .brownfield(let loaded)? = try ConfigLoader().loadProfile(
          repositoryRoot: base.appending(path: "repo"), commonDir: layout.commonDir)
      else {
        throw CocoaError(.fileReadCorruptFile)
      }
      areas = loaded.areas
    }

    /// The area's configured `test` command, as the config spells it.
    var configuredTest: String {
      get throws {
        try #require(
          config.split(separator: "\n").first { $0.hasPrefix("test = ") }
            .map { String($0.dropFirst("test = \"".count).dropLast()) })
      }
    }

    func run(
      _ test: String, area: String? = nil, runner: FakeAreaCommandRunner, xcresults: String,
      context: GateRun.Context? = nil
    ) async throws -> GateRunParts {
      try await TestOnlyCheck.run(
        root: root, test: test, area: area,
        context: context ?? GateRun.Context(runID: "run", directory: run),
        dependencies: TestOnlyCheck.Dependencies(
          areas: areas, layout: layout, trackedTree: TrackedTreeSnapshot(files: [:]),
          runner: runner, xcresults: FakeXcresultReader(scenario: xcresults),
          bound: { _, _ in AreaCommandBound(duration: .seconds(5), reason: "the flat 5 s") },
          changedTests: { _ in .success([]) }))
    }
  }

  private static func verdict(_ parts: GateRunParts) -> Verdict {
    Verdict.merged(
      parts.tiers.map(\.verdict)
        + (parts.findings.contains { $0.severity.failsGate } ? [.red] : []))
  }

  @Test(
    "the Aidoku trial's test that didn't compile reads RED from 1 run of the area's test command narrowed with -only-testing, quoting the compile errors, with no baseline or prove — catches the fixer finding each compile error through a 2-minute merge gate"
  )
  func compileFailureIsRedFromOneNarrowRun() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let tail = try Fixture.text("BrownfieldTrial/aidoku-validation-3-test-compile.tail.txt")
    let runner = FakeAreaCommandRunner { _ in .failed(exit: 65, tail: tail, junit: nil) }

    let parts = try await clone.run(Self.id, runner: runner, xcresults: "build-error")

    #expect(Self.verdict(parts) == .red)
    #expect(runner.requests.count == 1, "no baseline, prove or second step ran")
    let request = try #require(runner.requests.first)
    let bundle = clone.run.appending(path: "test-only.xcresult").path
    let derivedData = XcodeDerivedData.path(area: "Aidoku", layout: clone.layout)
    #expect(
      request.command
        == XcodeDerivedData.command(
          "\(try clone.configuredTest) -only-testing:'\(Self.id)' -resultBundlePath '\(bundle)'",
          derivedDataPath: derivedData),
      "\(request.command)")
    #expect(request.command.contains("-derivedDataPath '\(derivedData)'"), "\(request.command)")
    #expect(request.workingDirectory.hasPrefix(clone.root.path), "\(request.workingDirectory)")
    let finding = try #require(parts.findings.first { $0.severity.failsGate })
    #expect(finding.ruleID == BrownfieldRuleID.testFailed.rawValue)
    #expect(
      finding.message.contains("Member 'toggle' expects argument of type 'ToggleSetting'"),
      "\(finding.message)")
    #expect(finding.message.contains(Self.id))
  }

  @Test(
    "an exit 0 whose result bundle shows the test ran reads GREEN — catches a cheap loop that can't tell the fixer its fix compiled and passed"
  )
  func passingTestIsGreen() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let runner = FakeAreaCommandRunner { _ in .passed }

    let parts = try await clone.run(Self.id, runner: runner, xcresults: "one-test")

    #expect(Self.verdict(parts) == .green, "\(parts.findings.map(\.message))")
    #expect(runner.requests.count == 1)
  }

  @Test(
    "an exit 0 whose result bundle shows no test ran reads RED, naming the id — catches a misspelt id passing as a green loop"
  )
  func noTestMatchedIsRed() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let runner = FakeAreaCommandRunner { _ in .passed }

    let parts = try await clone.run(
      "AidokuTests/NoSuchTests", runner: runner, xcresults: "zero")

    #expect(Self.verdict(parts) == .red)
    let finding = try #require(parts.findings.first { $0.severity.failsGate })
    #expect(finding.message.contains("no test matched `AidokuTests/NoSuchTests`"), "\(finding.message)")
  }

  @Test(
    "an area the config doesn't hold is BLOCKED and runs nothing — catches a typo reading as a pass"
  )
  func unknownAreaIsBlocked() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let runner = FakeAreaCommandRunner { _ in .passed }

    let parts = try await clone.run(Self.id, area: "Web", runner: runner, xcresults: "one-test")

    #expect(Self.verdict(parts) == .blocked)
    #expect(runner.requests.isEmpty)
    #expect(parts.findings.contains { $0.message.contains("`Web` is no area") })
  }

  @Test(
    "an xcode area's run builds in the worktree's own DerivedData, never Xcode's global one, and its step is labelled cold, then warm once that DerivedData holds a build — catches the 1.3 GB folder a fixer's test-only left in ~/Library labelled none"
  )
  func xcodeRunBuildsInTheWorktreesDerivedData() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let runner = FakeAreaCommandRunner { _ in .passed }
    let derivedData = XcodeDerivedData.path(area: "Aidoku", layout: clone.layout)

    let cold = GateRun.Context(runID: "cold", directory: clone.run)
    _ = try await clone.run(Self.id, runner: runner, xcresults: "one-test", context: cold)
    try FileManager.default.createDirectory(
      atPath: derivedData + "/Build", withIntermediateDirectories: true)
    let warm = GateRun.Context(runID: "warm", directory: clone.run)
    _ = try await clone.run(Self.id, runner: runner, xcresults: "one-test", context: warm)

    #expect(runner.requests.count == 2)
    #expect(
      runner.requests.allSatisfy { $0.command.contains("-derivedDataPath '\(derivedData)'") },
      "\(runner.requests.map(\.command))")
    #expect(cold.steps.steps.filter { $0.step == .areaTest }.map(\.derivedData) == [.cold])
    #expect(warm.steps.steps.filter { $0.step == .areaTest }.map(\.derivedData) == [.warm])
  }

  /// price-tracker-3's detail test file, as the worker who wrote it ran it.
  static let detailTests = "Packages/AppFeature/Tests/AppCoreTests/DetailFeatureTests.swift"

  /// `test-only DetailFeatureTests --area AppFeature` in price-tracker-3's areas, each bound read
  /// from the warm-up that run measured, at the moment the worker's first run started.
  private static func priceTracker(
    _ clone: Clone, runner: FakeAreaCommandRunner, changed: [ChangedTestFile] = [],
    context: GateRun.Context
  ) async throws -> GateRunParts {
    let config = try TOMLConfigDecoder().decodeBrownfield(
      try Fixture.text("BrownfieldTrial/price-tracker-1-config.toml"))
    let times = try WarmupTimesFile.decode(
      Fixture.data("BrownfieldTrial/price-tracker-3-warmup.json"),
      tree: "f0bd7c247ed6a4afd220dfad6893cc719ca66bfa")
    let started = try #require(ISO8601DateFormatter().date(from: "2026-10-05T05:58:09Z"))
    let bounds = AreaCommandBounds(times: times, box: nil, tier: .slice, fallback: .seconds(3600))
    return try await TestOnlyCheck.run(
      root: clone.root, test: "DetailFeatureTests", area: "AppFeature", context: context,
      dependencies: TestOnlyCheck.Dependencies(
        areas: config.areas, layout: clone.layout, trackedTree: TrackedTreeSnapshot(files: [:]),
        runner: runner, xcresults: FakeXcresultReader(scenario: "one-test"),
        bound: { area, tree in
          bounds.bound(area: area, step: .testFiles, tree: tree, now: started)
        },
        changedTests: { _ in .success(changed) }))
  }

  @Test(
    "price-tracker-3's detail test that spins on `while !started.value { await Task.yield() }` is RED at once, naming the file and the loop's line, and nothing runs — catches test-only holding a worker 500 s, then 600 s, on a test that can only hang"
  )
  func spinningTestIsRedBeforeItRuns() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let runner = FakeAreaCommandRunner { _ in .timedOut(tail: "") }
    let text = try Fixture.text("BrownfieldTrial/price-tracker-3-DetailFeatureTests-spin.swift")
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
    let changed = ChangedTestFile(
      path: Self.detailTests, content: text,
      added: AddedLines(path: Self.detailTests, ranges: [1...lines]))

    let parts = try await Self.priceTracker(
      clone, runner: runner, changed: [changed],
      context: GateRun.Context(runID: "run", directory: clone.run))

    #expect(runner.requests.isEmpty, "\(runner.requests.map(\.command))")
    #expect(Self.verdict(parts) == .red)
    let gating = parts.findings.filter { $0.severity.failsGate }
    #expect(gating.map(\.ruleID) == ["test.unbounded-wait", "test.unbounded-wait"])
    #expect(gating.map(\.file) == [Self.detailTests, Self.detailTests])
    #expect(gating.map(\.line) == [100, 102])
  }

  @Test(
    "a test that hangs is killed at AppFeature's bound from the warm-up and is RED naming the hang and the bound: 161.4 s cold plus 5 warm runs with no build of the package yet, the 120 s floor once its shared scratch path exists — catches the 3600 s deadline the trial's hung test ran under"
  )
  func hungTestIsRedAtItsBound() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let runner = FakeAreaCommandRunner { _ in
      .timedOut(tail: "◇ Test \"dismissing the detail cancels a running chart request\" started.")
    }

    let cold = GateRun.Context(runID: "cold", directory: clone.run)
    let unbuilt = try await Self.priceTracker(clone, runner: runner, context: cold)
    try FileManager.default.createDirectory(
      atPath: ScratchTreeBuild.swiftPMScratchPath(area: "AppFeature", layout: clone.layout),
      withIntermediateDirectories: true)
    let warm = GateRun.Context(runID: "warm", directory: clone.run)
    let built = try await Self.priceTracker(clone, runner: runner, context: warm)

    #expect(
      runner.requests.map(\.deadline)
        == [.milliseconds(161_442 + 5 * 11_349), AreaCommandBounds.floor])
    #expect(cold.steps.steps.filter { $0.step == .areaTest }.map(\.derivedData) == [.cold])
    #expect(warm.steps.steps.filter { $0.step == .areaTest }.map(\.derivedData) == [.warm])
    for (parts, bound) in [(unbuilt, "219 s"), (built, "120 s")] {
      #expect(Self.verdict(parts) == .red)
      let finding = try #require(parts.findings.first { $0.severity.failsGate })
      #expect(finding.ruleID == BrownfieldRuleID.testFailed.rawValue)
      #expect(finding.message.contains("hung"), "\(finding.message)")
      #expect(finding.message.contains(bound), "\(finding.message)")
      #expect(finding.message.contains("cancels a running chart request"), "\(finding.message)")
    }
    let unbuiltFinding = try #require(unbuilt.findings.first { $0.severity.failsGate })
    #expect(unbuiltFinding.message.contains("161.4 s cold"), "\(unbuiltFinding.message)")
  }

  @Test(
    "a run the box leaves less time than the test's measured run isn't started, and is BLOCKED saying so — catches test-only started only to be killed at the cutoff"
  )
  func runThatCannotFinishIsNotStarted() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let runner = FakeAreaCommandRunner { _ in .passed }

    let parts = try await TestOnlyCheck.run(
      root: clone.root, test: Self.id, area: nil,
      context: GateRun.Context(runID: "run", directory: clone.run),
      dependencies: TestOnlyCheck.Dependencies(
        areas: clone.areas, layout: clone.layout, trackedTree: TrackedTreeSnapshot(files: [:]),
        runner: runner, xcresults: FakeXcresultReader(scenario: "one-test"),
        bound: { _, _ in
          AreaCommandBound(
            duration: .seconds(20), reason: "the 20 s left before the run's cutoff",
            expected: .seconds(55))
        },
        changedTests: { _ in .success([]) }))

    #expect(runner.requests.isEmpty)
    #expect(Self.verdict(parts) == .blocked)
    #expect(
      parts.findings.contains {
        $0.ruleID == CheckRun.notRunRuleID && $0.message.contains("20 s left")
      }, "\(parts.findings.map(\.message))")
  }
}

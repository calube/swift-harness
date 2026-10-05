import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

@testable import SwiftGateCLI

@Suite("brownfield slice tier")
struct BrownfieldSliceCheckTests {
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
        path: "swiftgate-brownfield-slice-\(UUID().uuidString)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    func inScratch(_ request: AreaCommandRequest) -> Bool {
      request.workingDirectory.hasPrefix(scratch.path(percentEncoded: false))
    }

    func relative(_ url: URL) -> String {
      let prefix = root.path(percentEncoded: false)
      let path = url.path(percentEncoded: false)
      return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
  }

  private static func area(
    _ name: String, kind: AreaKind = .python, language: AreaLanguage = .python,
    lint: String? = nil, build: String? = "build", xcode: XcodeAreaConfig? = nil
  ) -> BrownfieldArea {
    BrownfieldArea(
      name: name, root: name, language: language, kind: kind, test: "test-all",
      testFiles: "check {files}", lint: lint, build: build, e2e: nil,
      testGlobs: ["\(name)/tests/**"], packs: [], xcode: xcode)
  }

  /// 1 changed file: its text at the head, and the lines the change adds.
  private struct Change {
    let path: String
    let text: String
    let added: [ClosedRange<Int>]
    /// The file exists at the merge base.
    var existed = true
  }

  private static func run(
    _ clone: Clone, areas: [BrownfieldArea], changes: [Change],
    runner: any AreaCommandRunning, warm: [String: Int] = [:],
    history: [CommitTree] = [CommitTree(commit: "base0", tree: "tree0")],
    warmByTree: [String: [String: Int]] = [:],
    changedSince: [String: [String]] = [:],
    judge:
      @escaping @Sendable (AssertionCandidate, String) async
      -> BrownfieldSliceCheck.AssertionJudgement = { _, _ in .asserts },
    files: [String: String] = [:], context: GateRun.Context? = nil
  ) async throws -> GateRunParts {
    let git = FakeGit(
      changed: changes.map(\.path), mergeBase: "base0",
      addedSince: changes.map { AddedLines(path: $0.path, ranges: $0.added) },
      contentsAtRef: Dictionary(
        uniqueKeysWithValues: changes.filter(\.existed).map { ($0.path, "") }))
    let scratch = FakeScratchWorktrees(root: clone.scratch)
    var texts = files
    for change in changes { texts[change.path] = change.text }
    let known = texts
    let config = BrownfieldConfig(
      brownfield: BrownfieldSettings(
        discoveredAt: "base0", sliceBudgetSeconds: 30, timeBudgetMinutes: 0, sensitive: []),
      areas: areas, allow: [], buildPresets: [:])
    let dependencies = BrownfieldSliceCheck.Dependencies(
      config: config, layout: clone.layout, git: git, runner: runner,
      baseline: BaselineStore(layout: clone.layout, runner: runner, scratch: scratch),
      prove: BrownfieldProve.Dependencies(
        git: git, scratch: scratch, runner: runner,
        readFile: { known[clone.relative($0)] }, deadline: .seconds(5)),
      trackedTree: TrackedTreeSnapshot(files: [:]), tree: { _ in "tree0" },
      warmTestMilliseconds: { area, tree in
        tree == "tree0" ? warm[area.name] : warmByTree[tree]?[area.name]
      },
      history: { _ in history },
      changedBetween: { from, _ in changedSince[from] ?? [] },
      judgeAssertion: judge, deadline: .seconds(5))
    return try await BrownfieldSliceCheck.run(
      root: clone.root, base: "main",
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
    "an empty change and a 1-line change report nothing on untouched code — catches whole-file checks that flag lines the task never wrote"
  )
  func untouchedCodeHasNoFindings() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let gguf = BrownfieldArea(
      name: "gguf", root: "gguf-py", language: .python, kind: .python, test: "test-all",
      testFiles: "check {files}", lint: "flake8 {files}", build: nil, e2e: nil,
      testGlobs: ["gguf-py/tests/**"], packs: [], xcode: nil)
    let areas = [gguf, Self.area("web")]
    let flake8 = try Fixture.text("AreaRuns/python/lint/stdout")
    let runner = FakeAreaCommandRunner { request in
      request.step == .lint ? .failed(exit: 1, tail: flake8, junit: nil) : .passed
    }
    let path = "gguf-py/gguf/utility.py"
    let legacy =
      (["import os", "", "value = load()  # noqa"] + Array(repeating: "", count: 4)
      + ["import tempfile", ""]).joined(separator: "\n")

    let (empty, milliseconds) = try await GateRun.timed {
      try await Self.run(clone, areas: areas, changes: [], runner: runner)
    }
    #expect(empty.findings.filter { $0.severity != .nit }.isEmpty)
    #expect(Self.verdict(empty) == .green)
    #expect(runner.requests.isEmpty, "an empty change runs no area command")
    #expect(milliseconds < 30_000)

    let oneLine = try await Self.run(
      clone, areas: areas, changes: [Change(path: path, text: legacy, added: [1...1])],
      runner: runner)
    #expect(
      oneLine.findings.filter { $0.severity != .nit }.map { "\($0.ruleID) \($0.line ?? 0)" }
        == [])
    #expect(Self.verdict(oneLine) == .green)
    #expect(Set(runner.requests.map(\.area)) == ["gguf"], "only the touched area runs")

    let written = try await Self.run(
      clone, areas: areas, changes: [Change(path: path, text: legacy, added: [3...3, 8...8])],
      runner: runner)
    #expect(
      Self.gating(written) == ["neutral.lint \(path)", "neutral.unsafe-shortcut \(path)"],
      "the same lines, once added, are checked")
  }

  @Test(
    "a failing changed test the merge base fails too doesn't gate and counts once — catches slice gating on known failures, or a baselineCount that double counts"
  )
  func baselineAbsorbsKnownFailure() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let runner = FakeAreaCommandRunner { request in
      request.step == .testFiles
        ? .failed(exit: 1, tail: "1 failed", junit: nil) : .passed
    }
    let context = GateRun.Context(runID: "run", directory: clone.base)

    let parts = try await Self.run(
      clone, areas: [Self.area("api")],
      changes: [
        Change(path: "api/src/load.py", text: "def load():\n    return 2\n", added: [2...2]),
        Change(
          path: "api/tests/test_load.py",
          text: "def test_load():\n    assert load() == 2\n", added: [2...2]),
      ],
      runner: runner, warm: ["api": 1000], context: context)

    #expect(
      runner.requests.contains { $0.step == .testFiles && !clone.inScratch($0) },
      "the changed test ran at the head")
    #expect(Self.gating(parts) == [])
    #expect(parts.baselineCount == 1)
    #expect(parts.findings.contains { $0.ruleID == BrownfieldRuleID.baselineSummary.rawValue })
    #expect(context.steps.steps.contains { $0.step == .baseline })
    #expect(context.steps.steps.contains { $0.step == .areaTest && $0.area == "api" })
  }

  @Test(
    "a failing test in a file the merge base lacks gates even when the base run fails — catches a new test's failure absorbed as the whole step failing at the base"
  )
  func newTestFileFailureGates() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let runner = FakeAreaCommandRunner { request in
      request.step == .testFiles
        ? .failed(exit: 1, tail: "1 failed", junit: nil) : .passed
    }

    let parts = try await Self.run(
      clone, areas: [Self.area("api")],
      changes: [
        Change(path: "api/src/load.py", text: "def load():\n    return 2\n", added: [2...2]),
        Change(
          path: "api/tests/test_load.py",
          text: "def test_load():\n    assert load() == 2\n", added: [1...2], existed: false),
      ],
      runner: runner, warm: ["api": 1000])

    #expect(Self.gating(parts) == ["area.test-failed api"])
    #expect(parts.baselineCount == nil || parts.baselineCount == 0)
  }

  @Test(
    "an area whose warm test time is 45 s only builds and says so, while a 1 s area runs its changed tests — catches a slice that blows its 30 s budget on slow areas"
  )
  func slowAreaBuildsOnly() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let scratch = clone.scratch.path(percentEncoded: false)
    let runner = FakeAreaCommandRunner { request in
      request.step == .testFiles && request.workingDirectory.hasPrefix(scratch)
        ? .failed(exit: 1, tail: "1 failed", junit: nil) : .passed
    }
    let test = "def test_load():\n    assert load() == 2\n"

    let context = GateRun.Context(runID: "run", directory: clone.base)

    let parts = try await Self.run(
      clone, areas: [Self.area("app"), Self.area("api"), Self.area("cli")],
      changes: [
        Change(path: "app/src/load.py", text: "x = 1\n", added: [1...1]),
        Change(path: "app/tests/test_load.py", text: test, added: [2...2]),
        Change(path: "api/src/load.py", text: "x = 1\n", added: [1...1]),
        Change(path: "api/tests/test_load.py", text: test, added: [2...2]),
        Change(path: "cli/src/load.py", text: "x = 1\n", added: [1...1]),
      ],
      runner: runner, warm: ["app": 45_000, "api": 1000], context: context)

    let app = runner.requests.filter { $0.area == "app" }.map(\.step)
    #expect(app == [.build], "the slow area only builds")
    #expect(
      runner.requests.filter { $0.area == "app" }.map(\.command) == ["build"],
      "an area that isn't xcode keeps its own build")
    #expect(runner.requests.contains { $0.area == "api" && $0.step == .testFiles })
    #expect(
      context.proofs.results.map { "\($0.target) \($0.test) \($0.outcome.rawValue)" }
        == ["api tests/test_load.py proven"],
      "the gate run records the proof of the area that ran its tests, and only that one")
    let buildOnly = parts.findings.filter { $0.ruleID == BrownfieldRuleID.buildOnly.rawValue }
    #expect(buildOnly.map(\.file).sorted() == ["app", "cli"])
    #expect(buildOnly.allSatisfy { $0.severity == .nit })
    #expect(buildOnly.first { $0.file == "app" }?.message.contains("45") == true)
    #expect(
      buildOnly.first { $0.file == "cli" }?.message.contains("no warm-up") == true,
      "an unmeasured area says why it only builds")
    #expect(Self.verdict(parts) == .green)
  }

  @Test(
    "the trial's xcode area, build-only at its 45.7 s warm test, compiles its test target with build-for-testing on the test destination and runs no test — catches a test target that first compiles at the merge gate"
  )
  func buildOnlyXcodeAreaBuildsForTesting() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let config = try TOMLConfigDecoder().decodeBrownfield(
      try Fixture.text("BrownfieldTrial/aidoku-validation-config.toml"))
    let aidoku = try #require(config.areas.first)
    let test = try #require(aidoku.test)
    let runner = FakeAreaCommandRunner { _ in .passed }
    let context = GateRun.Context(runID: "run", directory: clone.base)

    let parts = try await Self.run(
      clone, areas: [aidoku],
      changes: [
        Change(
          path: "Aidoku/Shared/Managers/DownloadManager.swift", text: "let limit = 50\n",
          added: [1...1]),
        Change(
          path: "AidokuTests/LargeDownloadConfirmationTests.swift",
          text: "func testLimit() { XCTAssertEqual(limit, 50) }\n", added: [1...1]),
      ],
      runner: runner, warm: ["Aidoku": 45_700], context: context)

    let head = runner.requests.filter { $0.area == "Aidoku" && $0.step != .lint }
    #expect(
      head.map(\.command)
        == [
          test.replacingOccurrences(of: "xcodebuild test ", with: "xcodebuild build-for-testing ")
        ],
      "the build-only step compiles the test target on the scheme and destination its tests use")
    #expect(!runner.requests.contains { $0.step == .test || $0.step == .testFiles })
    #expect(context.steps.steps.contains { $0.step == .areaBuild && $0.area == "Aidoku" })
    let buildOnly = parts.findings.filter { $0.ruleID == BrownfieldRuleID.buildOnly.rawValue }
    #expect(buildOnly.count == 1)
    #expect(
      buildOnly.first?.message.contains("compiles its tests") == true,
      "\(buildOnly.map(\.message))")
    #expect(Self.verdict(parts) == .green)
  }

  @Test(
    "an area whose warm test time fits the budget but whose change selects no test still builds — catches a slice GREEN in a second on a commit that adds a type and compiles nothing"
  )
  func noSelectedTestStillBuilds() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let scratch = clone.scratch.path(percentEncoded: false)
    let runner = FakeAreaCommandRunner { request in
      request.step == .build && !request.workingDirectory.hasPrefix(scratch)
        ? .failed(exit: 65, tail: "** BUILD FAILED **", junit: nil) : .passed
    }
    let context = GateRun.Context(runID: "run", directory: clone.base)

    let parts = try await Self.run(
      clone, areas: [Self.area("api")],
      changes: [Change(path: "api/src/summary.py", text: "x = 1\n", added: [1...1])],
      runner: runner, warm: ["api": 2_455], context: context)

    #expect(
      runner.requests.contains { $0.area == "api" && $0.step == .build && !clone.inScratch($0) },
      "the change's code is compiled at the head")
    #expect(context.steps.steps.contains { $0.step == .areaBuild && $0.area == "api" })
    #expect(!runner.requests.contains { $0.step == .testFiles || $0.step == .test })
    #expect(Self.gating(parts) == ["area.build-failed api"])
  }

  @Test(
    "a lint whose tool isn't on PATH at the head and the merge base is reported as not installed, never absorbed — catches a missing linter that checks nothing all run behind the baseline"
  )
  func lintNotInstalledIsReported() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let missing = try Fixture.areaRun("swift/lint-not-installed")
    let runner = FakeAreaCommandRunner { request in request.step == .lint ? missing : .passed }
    let lint = "swiftlint lint --config .swiftlint.yml {files}"
    let path = "api/src/summary.py"

    let parts = try await Self.run(
      clone, areas: [Self.area("api", lint: lint)],
      changes: [Change(path: path, text: "x = 1\n", added: [1...1])], runner: runner)

    #expect(
      runner.requests.contains { $0.step == .lint && clone.inScratch($0) },
      "the merge base answers for the lint")
    #expect(parts.baselineCount == 0)
    #expect(
      !parts.findings.contains {
        $0.ruleID == BrownfieldRuleID.baselineSummary.rawValue && $0.message.contains("lint")
      })
    let dropped = parts.findings.filter {
      $0.ruleID == BrownfieldRuleID.stepDropped.rawValue && $0.message.contains("api lint")
    }
    #expect(dropped.count == 1)
    #expect(dropped.first?.message.contains("isn't installed") == true)
    #expect(dropped.first?.severity == .minor)
    #expect(Self.gating(parts) == [])
    let recorded = BaselineStore(
      layout: clone.layout, runner: runner, scratch: FakeScratchWorktrees(root: clone.scratch)
    ).load(tree: "tree0").results
    #expect(
      recorded[BaselineStepKey(area: "api", step: .lint, command: lint, selection: [path])]
        == .notInstalled)
  }

  /// A task branched from a plan branch: its merge base `base0` is a merge after the contract
  /// `contract0`, and only the run's base `start0` was warmed.
  private static let planHistory = [
    CommitTree(commit: "base0", tree: "tree0"), CommitTree(commit: "contract0", tree: "tree1"),
    CommitTree(commit: "start0", tree: "treeW"),
  ]

  @Test(
    "a task slice whose merge base descends from the warmed tree runs an unchanged area's changed tests and their prove — catches a slice that finds the warm-up only at its exact merge-base tree"
  )
  func descendantReusesWarmup() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let scratch = clone.scratch.path(percentEncoded: false)
    let runner = FakeAreaCommandRunner { request in
      request.step == .testFiles && request.workingDirectory.hasPrefix(scratch)
        ? .failed(exit: 1, tail: "1 failed", junit: nil) : .passed
    }
    let context = GateRun.Context(runID: "run", directory: clone.base)

    let parts = try await Self.run(
      clone, areas: [Self.area("api"), Self.area("web")],
      changes: [
        Change(path: "api/src/load.py", text: "x = 1\n", added: [1...1]),
        Change(
          path: "api/tests/test_load.py", text: "def test_load():\n    assert load() == 2\n",
          added: [2...2]),
      ],
      runner: runner, history: Self.planHistory, warmByTree: ["treeW": ["api": 1000]],
      changedSince: ["start0": ["web/src/contract.ts"]], context: context)

    #expect(
      runner.requests.contains { $0.area == "api" && $0.step == .testFiles && !clone.inScratch($0) }
    )
    #expect(
      context.proofs.results.map { "\($0.target) \($0.test) \($0.outcome.rawValue)" }
        == ["api tests/test_load.py proven"])
    #expect(!parts.findings.contains { $0.ruleID == BrownfieldRuleID.buildOnly.rawValue })
    #expect(Self.verdict(parts) == .green)
  }

  @Test(
    "an area changed since the warmed ancestor builds before its changed tests, and runs none when that build fails — catches stale warm state reused without bringing the area's build up to date"
  )
  func changedAreaBuildsFirst() async throws {
    let changes = [
      Change(path: "api/src/load.py", text: "x = 1\n", added: [1...1]),
      Change(
        path: "api/tests/test_load.py", text: "def test_load():\n    assert load() == 2\n",
        added: [2...2]),
    ]
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let scratch = clone.scratch.path(percentEncoded: false)
    let passing = FakeAreaCommandRunner { request in
      request.step == .testFiles && request.workingDirectory.hasPrefix(scratch)
        ? .failed(exit: 1, tail: "1 failed", junit: nil) : .passed
    }

    let built = try await Self.run(
      clone, areas: [Self.area("api")], changes: changes, runner: passing,
      history: Self.planHistory, warmByTree: ["treeW": ["api": 1000]],
      changedSince: ["start0": ["api/src/contract.py"]])

    let steps = passing.requests.filter { $0.area == "api" && !clone.inScratch($0) }.map(\.step)
    #expect(steps.prefix(2) == [.build, .testFiles], "the build runs, then the changed tests")
    #expect(Self.verdict(built) == .green)

    let breaking = FakeAreaCommandRunner { request in
      request.step == .build ? .failed(exit: 2, tail: "compile error", junit: nil) : .passed
    }
    let broken = try await Self.run(
      clone, areas: [Self.area("api")], changes: changes, runner: breaking,
      history: Self.planHistory, warmByTree: ["treeW": ["api": 1000]],
      changedSince: ["start0": ["api/src/contract.py"]])

    #expect(
      !breaking.requests.contains { $0.step == .testFiles },
      "a failed build leaves the warm-up's state behind, so no test runs on it")
    let buildOnly = broken.findings.filter { $0.ruleID == BrownfieldRuleID.buildOnly.rawValue }
    #expect(buildOnly.count == 1)
    #expect(buildOnly.first?.message.contains("start0") == true, "\(buildOnly.map(\.message))")
  }

  /// Holds each command, yielding, until `expected` are in flight at once or it has yielded
  /// `patience` times, and records the most that were in flight together.
  private final class Gathering: AreaCommandRunning {
    private struct State {
      var inFlight = 0
      var most = 0
    }
    private let state = Mutex(State())
    let expected: Int
    let patience: Int

    init(expected: Int, patience: Int) {
      self.expected = expected
      self.patience = patience
    }

    var most: Int { state.withLock { $0.most } }

    func run(_ request: AreaCommandRequest) async -> AreaCommandOutcome {
      state.withLock { state in
        state.inFlight += 1
        state.most = max(state.most, state.inFlight)
      }
      var yields = 0
      while state.withLock({ $0.most }) < expected, yields < patience {
        yields += 1
        await Task.yield()
      }
      state.withLock { $0.inFlight -= 1 }
      return .passed
    }
  }

  @Test(
    "3 touched areas run their commands at once — catches a serial walk over areas that multiplies the slice's time"
  )
  func areasRunTogether() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let runner = Gathering(expected: 3, patience: 100_000)

    let parts = try await Self.run(
      clone, areas: [Self.area("app"), Self.area("api"), Self.area("cli")],
      changes: ["app", "api", "cli"].map {
        Change(path: "\($0)/src/main.py", text: "x = 1\n", added: [1...1])
      },
      runner: runner)

    #expect(runner.most == 3)
    #expect(Self.verdict(parts) == .green)
  }

  @Test(
    "an assertion-free test the judge finds empty gates, one it finds asserting through a helper passes, and no answer is a non-gating note — catches the judge cascade skipped or its silence read as a pass"
  )
  func judgeRulesCandidates() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let runner = FakeAreaCommandRunner { _ in .passed }
    let change = Change(
      path: "api/tests/test_load.py", text: "def test_load():\n    load()\n", added: [1...2])
    let asked = RecordedStrings()

    func slice(_ answer: BrownfieldSliceCheck.AssertionJudgement) async throws -> GateRunParts {
      try await Self.run(
        clone, areas: [Self.area("api")], changes: [change], runner: runner,
        judge: { candidate, source in
          asked.append("\(candidate.path):\(candidate.line) \(source.count)")
          return answer
        })
    }

    let empty = try await slice(.assertsNothing)
    #expect(Self.gating(empty) == ["neutral.no-assertion api/tests/test_load.py"])
    #expect(asked.all == ["api/tests/test_load.py:1 \(change.text.count)"])

    let helper = try await slice(.asserts)
    #expect(!helper.findings.contains { $0.ruleID == BrownfieldRuleID.noAssertion.rawValue })

    let silent = try await slice(.unanswered("no backend"))
    let note = try #require(
      silent.findings.first { $0.ruleID == BrownfieldRuleID.noAssertion.rawValue })
    #expect(!note.severity.failsGate)
    #expect(note.message.contains("no backend"))
  }

  @Test(
    "a new Swift file no target of the area's project compiles is a finding, and one a target compiles is not — catches the Xcode membership check left out of slice"
  )
  func xcodeMembership() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let runner = FakeAreaCommandRunner { _ in .passed }
    let project = try Fixture.text("Xcode/explicit/tree/ios/KaMPKitiOS.xcodeproj/project.pbxproj")
    let area = BrownfieldArea(
      name: "ios", root: "ios", language: .swift, kind: .xcode, test: nil, testFiles: nil,
      lint: nil, build: "build", e2e: nil, testGlobs: ["ios/KaMPKitiOSTests/**"], packs: [],
      xcode: XcodeAreaConfig(
        workspace: nil, project: "ios/KaMPKitiOS.xcodeproj", inclusion: .explicit, manifest: nil,
        schemes: ["KaMPKitiOS"]))
    let context = GateRun.Context(runID: "run", directory: clone.base)

    let parts = try await Self.run(
      clone, areas: [area],
      changes: [
        Change(
          path: "ios/KaMPKitiOS/NewScreen.swift", text: "struct NewScreen {}\n", added: [1...1],
          existed: false),
        Change(
          path: "ios/KaMPKitiOS/AppDelegate.swift", text: "import UIKit\n", added: [1...1]),
      ],
      runner: runner, files: ["ios/KaMPKitiOS.xcodeproj/project.pbxproj": project],
      context: context)

    #expect(Self.gating(parts) == ["xcode.file-not-in-target ios/KaMPKitiOS/NewScreen.swift"])
    #expect(
      context.steps.steps.contains { $0.step == .xcodeMembership && $0.area == "ios" })
  }

  @Test(
    "gate.run carries the run's baselineCount — catches the count the baseline absorbed never reaching telemetry"
  )
  func gateRunCarriesBaselineCount() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "swiftgate-slice-events-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let log = MemoryEventLog()

    try await GateRun.execute(
      root: root, format: .json, command: "check slice",
      git: FakeGit(changed: [], mergeBase: "base", revisions: ["HEAD": "abc"]),
      checkTier: .slice, events: log, workingTree: nil
    ) { _ in
      var parts = GateRunParts(
        tiers: [
          try TierResult(tier: .t1, verdict: .green, durationMilliseconds: 1, testCounts: nil)
        ]
      )
      parts.baselineCount = 2
      return parts
    }

    let run = try #require(
      log.events.compactMap { event -> GateRunEvent? in
        guard case .gateRun(let run) = event.payload else { return nil }
        return run
      }.first)
    #expect(run.baselineCount == 2)
  }
}

/// Strings a test's closures record, in the order they arrive.
final class RecordedStrings: Sendable {
  private let stored = Mutex<[String]>([])

  func append(_ value: String) { stored.withLock { $0.append(value) } }

  var all: [String] { stored.withLock { $0 } }
}

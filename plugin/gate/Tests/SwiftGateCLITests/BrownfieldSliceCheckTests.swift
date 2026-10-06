import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

@testable import SwiftGateCLI

@Suite("brownfield slice tier", .timeLimit(.minutes(5)))
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
    lint: String? = nil, build: String? = "build", xcode: XcodeAreaConfig? = nil,
    testFiles: String? = "check {files}"
  ) -> BrownfieldArea {
    BrownfieldArea(
      name: name, root: name, language: language, kind: kind, test: "test-all",
      testFiles: testFiles, lint: lint, build: build, e2e: nil,
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
    records: [String: WarmupAreaRecord] = [:],
    box: RunTimeBox? = nil, now: Date = Date(timeIntervalSince1970: 0),
    judge:
      @escaping @Sendable (AssertionCandidate, String) async
      -> BrownfieldSliceCheck.AssertionJudgement = { _, _ in .asserts },
    files: [String: String] = [:], context: GateRun.Context? = nil, headTree: String? = nil
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
        readFile: { known[clone.relative($0)] }, deadline: .seconds(5), layout: clone.layout),
      trackedTree: TrackedTreeSnapshot(files: [:]), tree: { _ in "tree0" },
      warmup: { area, tree in
        if tree == "tree0", let record = records[area.name] { return record }
        return (tree == "tree0" ? warm[area.name] : warmByTree[tree]?[area.name]).map {
          WarmupAreaRecord(coldMilliseconds: 0, testMilliseconds: $0, steps: [.test: .passed])
        }
      },
      history: { _ in history },
      changedBetween: { from, _ in changedSince[from] ?? [] },
      judgeAssertion: judge, deadline: .seconds(5), headTree: headTree, box: box, now: { now })
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
    "an area whose warm test time is 45 s and whose test_files can't narrow a run only builds and says so, while a 1 s area runs its changed tests — catches a slice that blows its 30 s budget on slow areas"
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
      clone,
      areas: [Self.area("app", testFiles: nil), Self.area("api"), Self.area("cli", testFiles: nil)],
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
          XcodeDerivedData.command(
            test.replacingOccurrences(
              of: "xcodebuild test ", with: "xcodebuild build-for-testing "),
            derivedDataPath: XcodeDerivedData.path(area: "Aidoku", layout: clone.layout))
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
    "the captured view whose text field has an identifier and only a placeholder title is RED in slice, timed as the area's lint, and its labeled version is not — catches the field reaching the simulator audit at the last task's qa"
  )
  func unlabeledInputGatesSlice() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let runner = FakeAreaCommandRunner { _ in .passed }
    let area = Self.area("app", kind: .swiftpm, language: .swift, testFiles: nil)
    let path = "app/Sources/AppUI/DetailView.swift"
    func slice(_ variant: String) async throws -> (GateRunParts, GateRun.Context) {
      let text = try String(
        contentsOf: URL(filePath: #filePath)
          .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
          .appending(path: "Fixtures/rules/a11y.input-label/\(variant)/DetailView.swift"),
        encoding: .utf8)
      let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
      let context = GateRun.Context(runID: "run-\(variant)", directory: clone.base)
      let parts = try await Self.run(
        clone, areas: [area],
        changes: [Change(path: path, text: text, added: [1...lines], existed: false)],
        runner: runner, context: context)
      return (parts, context)
    }

    let (bad, context) = try await slice("bad")
    #expect(Self.gating(bad) == ["a11y.input-label \(path)"])
    #expect(bad.findings.first { $0.ruleID == "a11y.input-label" }?.line == 46)
    #expect(context.steps.steps.contains { $0.step == .lint && $0.area == "app" })

    let (good, _) = try await slice("good")
    #expect(Self.gating(good).isEmpty)
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

extension BrownfieldSliceCheckTests {
  /// Whether `request` runs in the scratch tree. An area rooted at `.` runs prove in the scratch
  /// tree's own directory, with no trailing slash for ``Clone/inScratch(_:)`` to match.
  private static func inScratchTree(_ request: AreaCommandRequest, _ clone: Clone) -> Bool {
    URL(filePath: request.workingDirectory, directoryHint: .isDirectory)
      .path(percentEncoded: false).hasPrefix(clone.scratch.path(percentEncoded: false))
  }

  @Test(
    "the trial's xcode area builds and tests at the head in the worktree's own DerivedData seeded from the area's seed, and prove's scratch tree in the worktree's prove DerivedData — catches a task worktree's first slice compiling cold in Xcode's path-keyed default, or a scratch tree overwriting the worktree's build",
    arguments: [45_700, 10_000])
  func xcodeHeadRunsUseTheWorktreeDerivedData(warm: Int) async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let config = try TOMLConfigDecoder().decodeBrownfield(
      try Fixture.text("BrownfieldTrial/aidoku-validation-config.toml"))
    let aidoku = try #require(config.areas.first)
    let runner = FakeAreaCommandRunner { _ in .passed }

    _ = try await Self.run(
      clone, areas: [aidoku],
      changes: [
        Change(
          path: "Aidoku/Shared/Managers/DownloadManager.swift", text: "let limit = 50\n",
          added: [1...1]),
        Change(
          path: "AidokuTests/LargeDownloadConfirmationTests.swift",
          text: "func testLimit() { XCTAssertEqual(limit, 50) }\n", added: [1...1]),
      ],
      runner: runner, warm: ["Aidoku": warm])

    let own = XcodeDerivedData.path(area: "Aidoku", layout: clone.layout)
    let seed = AreaCacheEnvironment.derivedDataSeed(area: "Aidoku", layout: clone.layout)
    let inScratch = { (request: AreaCommandRequest) in Self.inScratchTree(request, clone) }
    let head = runner.requests.filter { !inScratch($0) && $0.step != .lint }
    #expect(!head.isEmpty)
    for request in head {
      #expect(
        request.command.hasPrefix("xcodebuild -derivedDataPath '\(own)' "), "\(request.command)")
      #expect(request.derivedDataSeed == DerivedDataSeedCopy(seed: seed, destination: own))
    }
    #expect(runner.requests.contains(where: inScratch) == (warm < 30_000))
    let prove = clone.layout.worktreeRoot.appending(
      path: "derived-data/prove/Aidoku", directoryHint: .notDirectory
    ).path(percentEncoded: false)
    #expect(
      runner.requests.filter(inScratch).allSatisfy {
        $0.command.hasPrefix("xcodebuild -derivedDataPath '\(prove)' ")
          && $0.derivedDataSeed == DerivedDataSeedCopy(seed: seed, destination: prove)
      }, "prove builds in the worktree's prove DerivedData, never the worktree's own or Xcode's")
  }

  /// `text` as a `Change` that adds every line of a file the merge base lacks.
  private static func newFile(_ path: String, _ text: String) -> Change {
    Change(
      path: path, text: text,
      added: [1...text.split(separator: "\n", omittingEmptySubsequences: false).count - 1],
      existed: false)
  }

  /// Fails a selected run in the scratch tree, as the task's tests do with its source reverted,
  /// and passes everything else.
  private static func failsReverted(_ clone: Clone) -> FakeAreaCommandRunner {
    FakeAreaCommandRunner { request in
      request.step == .testFiles && Self.inScratchTree(request, clone)
        ? .failed(exit: 1, tail: "1 failed", junit: nil) : .passed
    }
  }

  @Test(
    "both trials' swiftpm areas narrow test_files to the changed tests and their xcode areas can't — catches slice and merge disagreeing on which area's changed tests slice runs"
  )
  func capturedAreasSelect() throws {
    for name in ["price-tracker-1", "send-money-2"] {
      let config = try TOMLConfigDecoder().decodeBrownfield(
        try Fixture.text("BrownfieldTrial/\(name)-config.toml"))
      let selecting = config.areas.filter(\.selectsChangedTests).map(\.name)
      #expect(selecting == ["APIClient", "AppFeature", "LogClient"], "\(name)")
    }
  }

  @Test(
    "price-tracker's AppFeature, over the 30 s budget at its 31.7 s warm test, still runs a task's new detail tests at the head through test_files --filter and proves them, and never runs its whole suite — catches a build-only slice that leaves a new test to run first at merge"
  )
  func overBudgetAreaRunsChangedTests() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let config = try TOMLConfigDecoder().decodeBrownfield(
      try Fixture.text("BrownfieldTrial/price-tracker-1-config.toml"))
    let runner = Self.failsReverted(clone)
    let context = GateRun.Context(runID: "run", directory: clone.base)

    let parts = try await Self.run(
      clone, areas: config.areas,
      changes: [
        Change(
          path: "Packages/AppFeature/Sources/AppCore/DetailFeature.swift",
          text: "let chart = 1\n", added: [1...1]),
        Self.newFile(
          Self.detailTests,
          try Fixture.text("BrownfieldTrial/price-tracker-3-DetailFeatureTests.swift")),
      ],
      runner: runner, warm: ["AppFeature": 31_700], context: context)

    let head = runner.requests.filter { $0.area == "AppFeature" && !Self.inScratchTree($0, clone) }
    let selected = try #require(head.first { $0.step == .testFiles }, "\(head.map(\.command))")
    #expect(selected.command.contains("--filter"))
    #expect(selected.command.contains("dismissCancelsChart"))
    #expect(!runner.requests.contains { $0.area == "AppFeature" && $0.step == .test })
    #expect(context.steps.steps.contains { $0.step == .areaTest && $0.area == "AppFeature" })
    #expect(
      context.proofs.results.filter { $0.target == "AppFeature" }.count == 5,
      "\(context.proofs.results.map(\.test))")
    #expect(
      !parts.findings.contains {
        $0.ruleID == BrownfieldRuleID.buildOnly.rawValue && $0.file == "Packages/AppFeature"
      })
    #expect(Self.verdict(parts) == .green)
  }

  /// price-tracker-3's detail task file, and the source it changed beside it.
  private static let detailTests =
    "Packages/AppFeature/Tests/AppCoreTests/DetailFeatureTests.swift"

  /// The warm-up price-tracker-3 measured: AppFeature's 11.3 s warm test and 161.4 s cold cost.
  private static func priceTrackerRecords() throws -> [String: WarmupAreaRecord] {
    try WarmupTimesFile.decode(
      Fixture.data("BrownfieldTrial/price-tracker-3-warmup.json"),
      tree: "f0bd7c247ed6a4afd220dfad6893cc719ca66bfa"
    ).areas
  }

  /// The detail task's change: its reducer and `file`'s text as its new test file.
  private static func detailChange(_ file: String) throws -> [Change] {
    [
      Change(
        path: "Packages/AppFeature/Sources/AppCore/DetailFeature.swift",
        text: "let chart = 1\n", added: [1...1]),
      Self.newFile(Self.detailTests, try Fixture.text("BrownfieldTrial/\(file)")),
    ]
  }

  @Test(
    "price-tracker-3's detail test that spins on `while !started.value { await Task.yield() }` is RED at once at both loops, with file and line, and AppFeature runs no test, prove or build — catches the slice that hung about 700 s on it until the cutoff"
  )
  func spinningTestIsRedBeforeAnyRun() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let config = try TOMLConfigDecoder().decodeBrownfield(
      try Fixture.text("BrownfieldTrial/price-tracker-1-config.toml"))
    let runner = Self.failsReverted(clone)

    let parts = try await Self.run(
      clone, areas: config.areas,
      changes: try Self.detailChange("price-tracker-3-DetailFeatureTests-spin.swift"),
      runner: runner, records: try Self.priceTrackerRecords())

    #expect(
      runner.requests.filter { $0.area == "AppFeature" }.isEmpty,
      "\(runner.requests.map(\.command))")
    #expect(Self.verdict(parts) == .red)
    let waits = parts.findings.filter { $0.ruleID == "test.unbounded-wait" }
    #expect(waits.map(\.file) == [Self.detailTests, Self.detailTests])
    #expect(waits.map(\.line) == [100, 102])
    #expect(waits.allSatisfy { $0.severity.failsGate })
  }

  @Test(
    "a changed test that hangs at the head is killed at AppFeature's bound from the warm-up, 161.4 s cold plus 5 warm runs with no build of the package yet, is RED naming the hang and the bound, and its prove doesn't start — catches slice waiting 600 s at the head and 600 s more in the prove scratch tree"
  )
  func hungHeadTestIsRedAtItsBound() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let config = try TOMLConfigDecoder().decodeBrownfield(
      try Fixture.text("BrownfieldTrial/price-tracker-1-config.toml"))
    let runner = FakeAreaCommandRunner { request in
      request.step == .testFiles
        ? .timedOut(tail: "◇ Test dismissCancelsChart() started.") : .passed
    }
    let context = GateRun.Context(runID: "run", directory: clone.base)

    let parts = try await Self.run(
      clone, areas: config.areas,
      changes: try Self.detailChange("price-tracker-3-DetailFeatureTests.swift"),
      runner: runner, records: try Self.priceTrackerRecords(), context: context)

    let tests = runner.requests.filter { $0.area == "AppFeature" && $0.step == .testFiles }
    #expect(tests.count == 1, "only the head ran: \(tests.map(\.workingDirectory))")
    #expect(tests.first?.deadline == .milliseconds(161_442 + 5 * 11_349))
    #expect(!context.steps.steps.contains { $0.step == .prove && $0.area == "AppFeature" })
    #expect(Self.verdict(parts) == .red)
    let finding = try #require(
      parts.findings.first { $0.ruleID == BrownfieldRuleID.testFailed.rawValue })
    #expect(finding.message.contains("hung"), "\(finding.message)")
    #expect(finding.message.contains("219 s"), "\(finding.message)")
    #expect(finding.message.contains("161.4 s cold"), "\(finding.message)")
    #expect(finding.message.contains("dismissCancelsChart() started"), "\(finding.message)")
  }

  @Test(
    "with AppFeature's shared scratch path built, the head run gets the 120 s floor and each prove run in the scratch tree the cold cost plus 5 warm runs — catches the flat 600 s every slice command, prove's included, ran under"
  )
  func headAndProveRunsGetTheirBounds() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let config = try TOMLConfigDecoder().decodeBrownfield(
      try Fixture.text("BrownfieldTrial/price-tracker-1-config.toml"))
    try FileManager.default.createDirectory(
      atPath: ScratchTreeBuild.swiftPMScratchPath(area: "AppFeature", layout: clone.layout),
      withIntermediateDirectories: true)
    let runner = Self.failsReverted(clone)

    let parts = try await Self.run(
      clone, areas: config.areas,
      changes: try Self.detailChange("price-tracker-3-DetailFeatureTests.swift"),
      runner: runner, records: try Self.priceTrackerRecords())

    let tests = runner.requests.filter { $0.area == "AppFeature" && $0.step == .testFiles }
    let head = tests.filter { !Self.inScratchTree($0, clone) }
    let proved = tests.filter { Self.inScratchTree($0, clone) }
    #expect(head.map(\.deadline) == [AreaCommandBounds.floor])
    #expect(!proved.isEmpty)
    #expect(
      proved.allSatisfy { $0.deadline == .milliseconds(161_442 + 5 * 11_349) },
      "\(proved.map(\.deadline))")
    #expect(Self.verdict(parts) == .green, "\(parts.findings.map(\.message))")
  }

  @Test(
    "at 06:26:43, 87.3 s before price-tracker-3's cutoff at 06:28:10.303, the head run is held to those 87.3 s on the gate's clock and its hang is RED naming the cutoff — catches a slice running past the box's cutoff"
  )
  func headRunIsCappedAtTheCutoff() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let config = try TOMLConfigDecoder().decodeBrownfield(
      try Fixture.text("BrownfieldTrial/price-tracker-1-config.toml"))
    let box = try #require(
      try RunClock.decode(Fixture.data("BrownfieldTrial/price-tracker-3-clock.json")).runTimeBox)
    let now = try #require(ISO8601DateFormatter().date(from: "2026-10-05T06:26:43Z"))
    let runner = FakeAreaCommandRunner { request in
      request.step == .testFiles ? .timedOut(tail: "") : .passed
    }

    let parts = try await Self.run(
      clone, areas: config.areas,
      changes: try Self.detailChange("price-tracker-3-DetailFeatureTests.swift"),
      runner: runner, records: try Self.priceTrackerRecords(), box: box, now: now)

    let head = runner.requests.filter { $0.area == "AppFeature" && $0.step == .testFiles }
    #expect(head.map(\.deadline) == [.milliseconds(87_303)])
    let finding = try #require(
      parts.findings.first { $0.ruleID == BrownfieldRuleID.testFailed.rawValue })
    #expect(finding.message.contains("88 s left before the run's cutoff"), "\(finding.message)")
  }

  @Test(
    "send-money's AppFeature, measured at 27.4 s before its files changed, whose build then takes the slice past its 30 s budget, still runs and proves the amount-entry task's new tests — catches slice deferring them to a merge that, judging by the warm time alone, never proves them"
  )
  func staleAreaOverBudgetRunsChangedTests() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let config = try TOMLConfigDecoder().decodeBrownfield(
      try Fixture.text("BrownfieldTrial/send-money-2-config.toml"))
    let warmup = try #require(
      try JSONSerialization.jsonObject(
        with: Data(try Fixture.text("BrownfieldTrial/send-money-2-warmup.json").utf8))
        as? [String: Any])
    let areas = try #require(warmup["areas"] as? [String: [String: Any]])
    let warmTest = try #require(areas["AppFeature"]?["testMs"] as? Int)
    let tree = try #require(warmup["tree"] as? String)
    let source = "Packages/AppFeature/Sources/AppCore/AmountInput.swift"
    let budget = Duration.milliseconds(30_000 - warmTest + 100)
    // The gate times its steps on a clock only the build moves, so the build takes the slice past
    // its budget without the test spending that time.
    let base = ContinuousClock.now
    let offset = Mutex(Duration.zero)
    let runner = FakeAreaCommandRunner { request in
      if request.step == .build, request.area == "AppFeature" {
        offset.withLock { $0 += budget }
      }
      return request.step == .testFiles && Self.inScratchTree(request, clone)
        ? .failed(exit: 1, tail: "1 failed", junit: nil) : .passed
    }
    let context = GateRun.Context(runID: "run", directory: clone.base)

    let now: @Sendable () -> ContinuousClock.Instant = { base + offset.withLock { $0 } }
    let parts = try await GateRun.$now.withValue(now) {
      try await Self.run(
        clone, areas: config.areas,
        changes: [
          Change(path: source, text: "let amount = 1\n", added: [1...1]),
          Self.newFile(
            "Packages/AppFeature/Tests/AppCoreTests/AmountInputTests.swift",
            try Fixture.text("BrownfieldTrial/send-money-2-AmountInputTests.swift")),
        ],
        runner: runner,
        history: [
          CommitTree(commit: "base0", tree: "tree0"), CommitTree(commit: "warm0", tree: tree),
        ],
        warmByTree: [tree: ["AppFeature": warmTest]], changedSince: ["warm0": [source]],
        context: context)
    }

    let head = runner.requests.filter { $0.area == "AppFeature" && !Self.inScratchTree($0, clone) }
    #expect(head.map(\.step) == [.build, .testFiles])
    let build = context.steps.steps.first { $0.step == .areaBuild && $0.area == "AppFeature" }
    #expect(
      build.map { $0.milliseconds + warmTest > 30_000 } == true, "\(String(describing: build))")
    #expect(context.proofs.results.filter { $0.target == "AppFeature" }.count == 8)
    #expect(
      !parts.findings.contains {
        $0.ruleID == BrownfieldRuleID.buildOnly.rawValue && $0.file == "Packages/AppFeature"
      }, "\(parts.findings.map(\.message))")
  }

  @Test(
    "a slice step that builds labels its DerivedData: price-tracker's xcode build warm when the worktree's Build folder exists, AppFeature's swiftpm build cold with no .build, and the neutral rules none — catches every step labelled none, so telemetry can't tell a 133 s cold build from a warm one"
  )
  func buildStepsLabelTheirDerivedData() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let config = try TOMLConfigDecoder().decodeBrownfield(
      try Fixture.text("BrownfieldTrial/price-tracker-1-config.toml"))
    try FileManager.default.createDirectory(
      atPath: XcodeDerivedData.path(area: "TimedBuildStarter", layout: clone.layout) + "/Build",
      withIntermediateDirectories: true)
    let context = GateRun.Context(runID: "run", directory: clone.base)

    _ = try await Self.run(
      clone, areas: config.areas,
      changes: [
        Change(path: "App/RootView.swift", text: "let root = 1\n", added: [1...1]),
        Change(
          path: "Packages/AppFeature/Sources/AppCore/WatchlistFeature.swift",
          text: "let list = 1\n", added: [1...1]),
      ],
      runner: FakeAreaCommandRunner { _ in .passed },
      warm: ["TimedBuildStarter": 76_800, "AppFeature": 31_700], context: context)

    let labels = context.steps.steps.map { "\($0.area ?? "-") \($0.step.rawValue) \($0.derivedData)" }
    #expect(labels.contains("TimedBuildStarter area-build warm"), "\(labels)")
    #expect(labels.contains("AppFeature area-build cold"), "\(labels)")
    #expect(labels.contains("AppFeature neutral none"), "\(labels)")
  }
}

extension BrownfieldSliceCheckTests {
  @Test(
    "the send-money trial's slice builds its scratch trees in the clone's caches: the baseline rerun's xcodebuild in the worktree's prove DerivedData, its swift build and prove's swift test in the worktree's prove scratch path for the area, and each step says whether that was warm and prove how long its runs waited for that path — catches a RED slice's baseline writing 1.3 GB into Xcode's global DerivedData, every swiftpm prove compiling cold while labelled none, and the send-money trial's proves taking turns on 1 shared scratch path with no step showing the wait",
    arguments: [false, true])
  func scratchTreesBuildInTheClonesCaches(warm: Bool) async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let config = try TOMLConfigDecoder().decodeBrownfield(
      try Fixture.text("BrownfieldTrial/send-money-3-config.toml"))
    let areas = config.areas.filter { ["TimedBuildStarter", "AppFeature"].contains($0.name) }
    let shared = ScratchTreeBuild.proveScratchPath(area: "AppFeature", layout: clone.layout)
    #expect(shared != ScratchTreeBuild.swiftPMScratchPath(area: "AppFeature", layout: clone.layout))
    let prove = XcodeDerivedData.provePath(area: "TimedBuildStarter", layout: clone.layout)
    if warm {
      for directory in [shared, prove + "/Build"] {
        try FileManager.default.createDirectory(
          atPath: directory, withIntermediateDirectories: true)
      }
    }
    // Both areas fail at the head and at the base, so the baseline reruns each in a scratch tree.
    // Each run that takes its turn in a build directory waited 250 ms for it.
    let runner = FakeAreaCommandRunner { request in
      request.buildLock?.waits.add(milliseconds: 250)
      return switch request.step {
      case .build: .failed(exit: 65, tail: "BUILD FAILED", junit: nil)
      case .testFiles: .failed(exit: 1, tail: "1 failed", junit: nil)
      default: .passed
      }
    }
    let context = GateRun.Context(runID: "run", directory: clone.base)
    let tests = try Fixture.text("BrownfieldTrial/send-money-2-AmountInputTests.swift")

    _ = try await Self.run(
      clone, areas: areas,
      changes: [
        Change(path: "App/TimedBuildStarterApp.swift", text: "let root = 1\n", added: [1...1]),
        Change(
          path: "Packages/AppFeature/Sources/AppCore/AmountInput.swift",
          text: "let amount = 1\n", added: [1...1]),
        Change(
          path: "Packages/AppFeature/Tests/AppCoreTests/AmountInputTests.swift", text: tests,
          added: [1...tests.split(separator: "\n", omittingEmptySubsequences: false).count - 1]),
      ],
      runner: runner, warm: ["TimedBuildStarter": 56_700, "AppFeature": 10_000], context: context)

    let scratch = runner.requests.filter { Self.inScratchTree($0, clone) }
    let starter = scratch.filter { $0.area == "TimedBuildStarter" }
    let feature = scratch.filter { $0.area == "AppFeature" }
    #expect(starter.map(\.step) == [.build], "the baseline reruns the failed build at the base")
    #expect(
      starter.allSatisfy { $0.command.hasPrefix("xcodebuild -derivedDataPath '\(prove)' ") },
      "\(starter.map(\.command))")
    #expect(
      feature.map(\.step) == [.build, .testFiles],
      "prove's failing build of the reverted tree, then the baseline's rerun at the base")
    #expect(
      feature.allSatisfy { $0.command.contains(" --scratch-path '\(shared)'") },
      "\(feature.map(\.command))")

    let label = warm ? "warm" : "cold"
    let labels = context.steps.steps.map { "\($0.area ?? "-") \($0.step.rawValue) \($0.derivedData)" }
    #expect(labels.contains("AppFeature prove \(label)"), "\(labels)")
    #expect(labels.contains("- baseline \(label)"), "\(labels)")
    let proved = feature.filter { $0.buildLock != nil }
    #expect(!proved.isEmpty, "prove's reverted runs take their turn")
    #expect(
      context.steps.steps.first { $0.step == .prove }?.lockWaitMilliseconds == 250 * proved.count)
  }
}

extension BrownfieldSliceCheckTests {
  private static let watchlistTests =
    "Packages/AppFeature/Tests/AppCoreTests/WatchlistFeatureTests.swift"
  private static let appFeatureTests =
    "Packages/AppFeature/Tests/AppCoreTests/AppFeatureTests.swift"
  /// The watchlist prove, run again by hand on the trial's repository.
  private static let proveReverted = "BrownfieldTrial/price-tracker-5-prove-reverted"

  /// price-tracker-5's watchlist task: its reducer, its 9 new watchlist tests and the root
  /// test it rewrote, as its slice gated them.
  private static func watchlistChange() throws -> [Change] {
    let root = try Fixture.text("\(Self.proveReverted)/AppFeatureTests.swift")
    return [
      Change(
        path: "Packages/AppFeature/Sources/AppCore/WatchlistFeature.swift",
        text: "let watchlist = 1\n", added: [1...1]),
      Self.newFile(
        Self.watchlistTests,
        try Fixture.text("\(Self.proveReverted)/WatchlistFeatureTests.swift")),
      Change(
        path: Self.appFeatureTests, text: root,
        added: [1...root.split(separator: "\n", omittingEmptySubsequences: false).count - 1]),
    ]
  }

  @Test(
    "price-tracker-5's watchlist prove, whose reverted source doesn't compile its tests, builds the tests once in the scratch tree, proves all 10 changed tests on that build failure and runs no test command there, timing the build as prove-build — catches the 92 s prove that ran 1 failing build per test, 11 in all"
  )
  func failingProveBuildProvesEveryTestOnce() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let config = try TOMLConfigDecoder().decodeBrownfield(
      try Fixture.text("BrownfieldTrial/price-tracker-5-config.toml"))
    let build = try Fixture.text("\(Self.proveReverted)/build.stdout")
    let together = try Fixture.text("\(Self.proveReverted)/together.stderr")
    let runner = FakeAreaCommandRunner { request in
      guard Self.inScratchTree(request, clone) else { return .passed }
      return request.command.hasPrefix("swift build")
        ? .failed(exit: 1, tail: build, junit: nil) : .failed(exit: 1, tail: together, junit: nil)
    }
    let context = GateRun.Context(runID: "run", directory: clone.base)

    _ = try await Self.run(
      clone, areas: config.areas, changes: try Self.watchlistChange(), runner: runner,
      warm: ["AppFeature": 22_600], context: context)

    let scratch = runner.requests.filter { Self.inScratchTree($0, clone) }
    #expect(scratch.map(\.step) == [.build], "\(scratch.map(\.command))")
    let prove = ScratchTreeBuild.proveScratchPath(area: "AppFeature", layout: clone.layout)
    #expect(
      scratch.first?.command == "swift build --scratch-path '\(prove)' --build-tests",
      "\(scratch.map(\.command))")
    let proofs = context.proofs.results.filter { $0.target == "AppFeature" }
    #expect(proofs.count == 10, "\(proofs.map(\.test))")
    #expect(proofs.allSatisfy { $0.outcome == .proven })
    #expect(
      proofs.first { $0.test.hasSuffix("hostsWatchlist()") }?.assertion?.file
        == Self.appFeatureTests)
    let steps = context.steps.steps.filter { $0.area == "AppFeature" }
    #expect(
      steps.filter { [.proveBuild, .proveTest].contains($0.step) }.map(\.step) == [.proveBuild])
    #expect(steps.first { $0.step == .proveBuild }?.verdict == .red)
  }

  @Test(
    "a captured swift test run of 3 changed tests that failed 2 and passed 1 with the source reverted is read from its report: the 2 are proven, the third neutral.not-proven, and no test runs again alone — catches prove rerunning every test of a failed run 1 at a time when the report already names each"
  )
  func failedRunIsReadFromItsReport() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let probe = BrownfieldArea(
      name: "Probe", root: "Probe", language: .swift, kind: .swiftpm,
      test: "swift test --parallel --xunit-output {junit}",
      testFiles: "swift test --parallel --xunit-output {junit} --filter {tests}", lint: nil,
      build: "swift build", e2e: nil, testGlobs: ["Probe/Tests/**"], packs: [], xcode: nil)
    let report = try #require(
      JUnitReports.combined([
        try Fixture.data("SwiftTest/prove-together.xml"),
        try Fixture.data("SwiftTest/prove-together-swift-testing.xml"),
      ]))
    let stdout = try Fixture.text("SwiftTest/prove-together.stdout")
    let runner = FakeAreaCommandRunner { request in
      guard Self.inScratchTree(request, clone), request.step == .testFiles else { return .passed }
      return .failed(exit: 1, tail: stdout, junit: report)
    }
    let context = GateRun.Context(runID: "run", directory: clone.base)
    let tests = "Probe/Tests/LibTests/DoubleTests.swift"

    let parts = try await Self.run(
      clone, areas: [probe],
      changes: [
        Change(
          path: "Probe/Sources/Lib/Lib.swift",
          text: "public func double(_ value: Int) -> Int { value * 2 }\n", added: [1...1]),
        Self.newFile(tests, try Fixture.text("SwiftTest/prove-together-DoubleTests.swift")),
      ],
      runner: runner, warm: ["Probe": 1_000], context: context)

    let runs = runner.requests.filter { Self.inScratchTree($0, clone) && $0.step == .testFiles }
    #expect(runs.count == 1, "\(runs.map(\.command))")
    #expect(Self.gating(parts) == ["neutral.not-proven \(tests)"])
    let outcomes = Dictionary(
      uniqueKeysWithValues: context.proofs.results.map { ($0.test, $0.outcome) })
    #expect(
      outcomes == [
        "LibTests.DoubleTests/doublesThree()": .proven,
        "LibTests.DoubleTests/doublesFour()": .proven,
        "LibTests.DoubleTests/keepsZero()": .passesReverted,
      ])
    #expect(
      context.steps.steps.filter { $0.area == "Probe" && $0.step == .proveTest }.map(\.verdict)
        == [.red])
  }
}

/// Fired once; a waiter waits for it with no bound of its own, so a loaded machine that fires it
/// late can't read as one that never fires. A wait that never ends is a regression the suite's
/// time limit ends by cancelling it.
final class OnceSignal: Sendable {
  private struct State {
    var fired = false
    var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    var cancelled: Set<UUID> = []
  }

  private let state = Mutex(State())

  var fired: Bool { state.withLock { $0.fired } }

  func fire() {
    let waiting = state.withLock { state in
      state.fired = true
      defer { state.waiters = [:] }
      return state.waiters
    }
    for continuation in waiting.values { continuation.resume() }
  }

  /// Whether the signal fired, once it has or the wait is cancelled.
  func wait() async -> Bool {
    await untilFired()
    return fired
  }

  private func untilFired() async {
    let id = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let done = state.withLock { state in
          if state.fired || state.cancelled.contains(id) { return true }
          state.waiters[id] = continuation
          return false
        }
        if done { continuation.resume() }
      }
    } onCancel: {
      let waiting = state.withLock { state in
        state.cancelled.insert(id)
        return state.waiters.removeValue(forKey: id)
      }
      waiting?.resume()
    }
  }
}

extension BrownfieldSliceCheckTests {
  @Test(
    "price-tracker-5's watchlist slice asks the judge about its TestStore tests while AppFeature's build and tests already run, rather than before them — catches the 61 s neutral step that held AppFeature's build back until every judge call had answered"
  )
  func judgeCallsOverlapTheAreaBuild() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let config = try TOMLConfigDecoder().decodeBrownfield(
      try Fixture.text("BrownfieldTrial/price-tracker-5-config.toml"))
    let started = OnceSignal()
    let runner = FakeAreaCommandRunner { request in
      if request.area == "AppFeature" { started.fire() }
      return Self.inScratchTree(request, clone)
        ? .failed(exit: 1, tail: "1 failed", junit: nil) : .passed
    }
    let answers = RecordedStrings()

    _ = try await Self.run(
      clone, areas: config.areas, changes: try Self.watchlistChange(), runner: runner,
      warm: ["AppFeature": 22_600],
      judge: { _, _ in
        guard !answers.all.contains("before") else { return .asserts }
        answers.append(await started.wait() ? "during" : "before")
        return .asserts
      })

    #expect(!answers.all.isEmpty, "the watchlist tests reached no judge")
    #expect(!answers.all.contains("before"), "\(answers.all)")
  }
}

extension BrownfieldSliceCheckTests {
  /// send-money-7's TimedBuildStarter `build-for-testing` answer at its contract's tree: what a
  /// later slice's 111 s cold baseline rerun wrote there, after an earlier slice had passed the
  /// same step on that same clean tree.
  private static func contractBuildForTesting() throws -> BaselineRecord {
    let file = try BaselineFile.decode(
      try Fixture.data("BrownfieldTrial/send-money-7-baseline-contract.json"),
      tree: "bf8ec9fb54cc37235d92d4b06cd15cc7d11d55ca")
    return try #require(file.records.first { $0.key.area == "TimedBuildStarter" })
  }

  @Test(
    "a slice on a clean tree records each step it passed as that tree's baseline answer, the same key send-money-7's cold rerun wrote, so a later slice measuring from that tree finds the app's build-for-testing answered and reruns none of it — catches 111 s of baseline rerun at a tree an earlier gate had already passed"
  )
  func passedStepsAnswerTheBaselineAtTheirTree() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let config = try TOMLConfigDecoder().decodeBrownfield(
      try Fixture.text("BrownfieldTrial/send-money-7-config.toml"))
    let change = Change(
      path: "Packages/AppFeature/Sources/AppCore/AppFeature.swift",
      text: "struct AppFeature {}\n", added: [1...1])
    let captured = try Self.contractBuildForTesting()

    _ = try await Self.run(
      clone, areas: config.areas, changes: [change],
      runner: FakeAreaCommandRunner { _ in .passed }, headTree: "tree0")

    let store = BaselineStore(
      layout: clone.layout, runner: FakeAreaCommandRunner { _ in .passed },
      scratch: FakeScratchWorktrees(root: clone.scratch))
    #expect(store.load(tree: "tree0").results[captured.key] == .passed)

    let broken = FakeAreaCommandRunner { request in
      request.area == "TimedBuildStarter" && request.step == .build && !clone.inScratch(request)
        ? .failed(exit: 65, tail: "error: cannot find 'AmountView' in scope", junit: nil)
        : .passed
    }
    let parts = try await Self.run(
      clone, areas: config.areas, changes: [change], runner: broken)

    #expect(!broken.requests.contains { clone.inScratch($0) && $0.area == "TimedBuildStarter" })
    #expect(
      parts.findings.contains {
        $0.ruleID == "area.build-failed" && $0.severity.failsGate
      }, "\(parts.findings.map(\.message))")
  }

  @Test(
    "a slice with no clean head tree records nothing in the baseline — catches uncommitted work's passes answering for a commit's tree"
  )
  func dirtyTreeRecordsNoBaseline() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let config = try TOMLConfigDecoder().decodeBrownfield(
      try Fixture.text("BrownfieldTrial/send-money-7-config.toml"))
    let change = Change(
      path: "Packages/AppFeature/Sources/AppCore/AppFeature.swift",
      text: "struct AppFeature {}\n", added: [1...1])

    _ = try await Self.run(
      clone, areas: config.areas, changes: [change],
      runner: FakeAreaCommandRunner { _ in .passed })

    #expect(!FileManager.default.fileExists(atPath: clone.layout.baseline(tree: "tree0").path))
  }
}

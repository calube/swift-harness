import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateRules

/// `test-only <id>`: 1 test through a brownfield area's own test command, narrowed to `id`, with
/// no baseline or prove, and of the lint only `test.unbounded-wait` over the area's changed tests.
/// It compiles what the test needs and runs it under the area's bound, so a fixer or worker
/// iterates on a compile or test failure in a fraction of a merge gate.
enum TestOnlyCheck {
  struct Dependencies: Sendable {
    let areas: [BrownfieldArea]
    let layout: BrownfieldStateLayout
    let trackedTree: TrackedTreeSnapshot
    let runner: any AreaCommandRunning
    let xcresults: any XcresultReader
    /// The area's bound for its test command run in `tree`, taken as the command starts.
    let bound: @Sendable (_ area: String, _ tree: AreaCommandTree) -> AreaCommandBound
    /// The area's test files the change adds or edits, with their added lines; a failure names
    /// why git couldn't say.
    let changedTests:
      @Sendable (_ area: BrownfieldArea) async -> Result<
        [ChangedTestFile], BrownfieldCheckSetupError
      >

    /// The clone's config and state, and `/bin/sh` commands. Each bound reads the nearest
    /// warm-up on HEAD's first-parent history that measured the area, under the box of the
    /// `swiftgate run` going on; the changed tests are those since the merge base with the commit
    /// discover ran at.
    static func live(root: URL) async throws(BrownfieldCheckSetupError) -> Dependencies {
      let merge = try await BrownfieldMergeCheck.Dependencies.live(root: root)
      let layout = merge.layout
      let history =
        (try? await BrownfieldSliceCheck.firstParentHistory(of: "HEAD", root: root)) ?? []
      let times = nearestWarmups(merge.config.areas, history: history, layout: layout)
      let box = ActiveRunTimeBox.find(
        layout: layout, now: Date(),
        finalSeconds: MeasuredFinalGateReader.seconds(worktree: root))
      let bounds = AreaCommandBounds(
        times: times, box: box, tier: .slice,
        fallback: BrownfieldSliceCheck.Dependencies.liveDeadline)
      let base = merge.config.brownfield.discoveredAt
      return Dependencies(
        areas: merge.config.areas, layout: layout, trackedTree: merge.trackedTree,
        runner: merge.runner, xcresults: LiveXcresultReader(runner: LiveProcessRunner()),
        bound: { area, tree in
          bounds.bound(area: area, step: .testFiles, tree: tree, now: Date())
        },
        changedTests: { [git = merge.git, readFile = merge.prove.readFile] area in
          do throws(GitError) {
            guard let mergeBase = try await git.mergeBase("HEAD", base) else {
              return .failure(
                BrownfieldCheckSetupError(reason: "HEAD and \(base) share no history"))
            }
            return .success(
              try await git.addedLines(since: mergeBase).compactMap { added in
                guard ChangedTestIDs.isTestFile(added.path, of: area),
                  let content = readFile(root.appending(path: added.path))
                else { return nil }
                return ChangedTestFile(path: added.path, content: content, added: added)
              })
          } catch {
            return .failure(BrownfieldCheckSetupError(reason: "git: \(error)"))
          }
        })
    }

    /// Each area's record from the nearest entry of `history` whose warm-up measured its tests.
    private static func nearestWarmups(
      _ areas: [BrownfieldArea], history: [CommitTree], layout: BrownfieldStateLayout
    ) -> WarmupTimesFile {
      let store = WarmupTimesStore(layout: layout)
      var found: [String: WarmupAreaRecord] = [:]
      var pending = Set(areas.map(\.name))
      for entry in history where !pending.isEmpty {
        for (name, record) in store.load(tree: entry.tree).file.areas
        where pending.contains(name) && record.warmTestMilliseconds != nil {
          found[name] = record
          pending.remove(name)
        }
      }
      return WarmupTimesFile(tree: "", areas: found)
    }
  }

  /// - Parameters:
  ///   - test: what the area's filter takes: `<Target>/<Class>[/<method>]` for an `xcode` area.
  ///   - area: the area to run it in; `nil` takes the 1 area that runs tests.
  static func run(
    root: URL, test: String, area: String?, context: GateRun.Context,
    dependencies: Dependencies
  ) async throws -> GateRunParts {
    let junit = context.directory.appending(path: "test-only.junit.xml").path(
      percentEncoded: false)
    let bundle = context.directory.appending(path: "test-only.xcresult").path(
      percentEncoded: false)
    let resolved: AcceptanceTestCommand
    switch AcceptanceTestReference(area: area, id: test).resolve(
      in: dependencies.areas, junitPath: junit, resultBundlePath: bundle)
    {
    case .success(let found): resolved = found
    case .failure(let unresolved): return try notRun(unresolved.reason)
    }
    guard let owner = dependencies.areas.first(where: { $0.name == resolved.area }) else {
      return try notRun("area `\(resolved.area)` isn't in the config")
    }
    var notes: [Finding] = []
    let (waits, lintMilliseconds) = await GateRun.timed {
      switch await dependencies.changedTests(owner) {
      case .success(let files): return ChangedTestWaits.findings(files)
      case .failure(let error):
        notes += note(
          "can't list \(owner.name)'s changed tests, so none was checked for a wait "
            + "with no bound: \(error.reason)")
        return []
      }
    }
    context.steps.record(
      .testlint, tier: nil, milliseconds: lintMilliseconds,
      verdict: waits.isEmpty ? .green : .red, area: owner.name)
    // A loop with no bound can only spin until the command's bound kills it.
    guard waits.isEmpty else {
      return GateRunParts(
        tiers: [
          try TierResult(tier: .t1, verdict: .red, durationMilliseconds: 0, testCounts: nil)
        ],
        findings: waits + notes)
    }

    let directory = resolved.root == "." ? root : root.appending(path: resolved.root)
    let environment = AreaCacheEnvironment.make(
      area: owner, layout: dependencies.layout, tree: dependencies.trackedTree
    ).variables
    let unplaced = AreaCommandRequest(
      area: owner.name, step: .testFiles, command: resolved.command,
      workingDirectory: directory.path(percentEncoded: false), deadline: .zero,
      environment: environment, junitPath: resolved.command.contains(junit) ? junit : nil)
    // An `xcodebuild` builds in the worktree's own DerivedData, never Xcode's global one.
    let placed = XcodeDerivedData.request(unplaced, layout: dependencies.layout)
    let derivedData = GateStepCollector.derivedData(
      buildDirectories: XcodeDerivedData.buildDirectories(
        placed, kind: owner.kind, layout: dependencies.layout
      ).map { URL(filePath: $0, directoryHint: .isDirectory) })
    let bound = dependencies.bound(
      owner.name, derivedData == .warm ? .checkout : .unbuiltCheckout)
    if bound.cannotFinish {
      let expected = bound.expected.map { " its measured \($0.components.seconds) s" } ?? ""
      return try notRun(
        "\(owner.name) test `\(test)` not started: \(bound.reason) can't hold\(expected), so it "
          + "would only be killed")
    }
    let request = AreaCommandRequest(
      area: placed.area, step: placed.step, command: placed.command,
      workingDirectory: placed.workingDirectory, deadline: bound.duration,
      environment: placed.environment, junitPath: placed.junitPath,
      resultBundlePath: placed.resultBundlePath, derivedDataSeed: placed.derivedDataSeed)
    let (outcome, milliseconds) = await GateRun.timed { await dependencies.runner.run(request) }
    context.steps.record(
      .areaTest, tier: nil, milliseconds: milliseconds,
      verdict: outcome == .passed ? .green : .red, derivedData: derivedData, area: owner.name)

    let what = "\(owner.name) test `\(test)`"
    let failure: String
    switch outcome {
    case .passed:
      var read: QACheckJudgement.ResultBundle?
      if let path = resolved.resultBundlePath {
        do {
          read = .tests(try await dependencies.xcresults.read(bundlePath: path).testResults)
        } catch {
          read = .unread(error.message)
        }
      }
      let judgement = QACheckJudgement.judge(
        QACheckJudgement.Input(
          end: .exited(0), stdout: "", stderr: "", report: JUnitReportFiles.read(at: junit),
          resultBundle: read, reference: test, atBase: false,
          roots: [root.path(percentEncoded: false)]))
      guard judgement.result != .pass else {
        return GateRunParts(
          tiers: [
            try TierResult(
              tier: .t1, verdict: .green, durationMilliseconds: milliseconds, testCounts: nil)
          ],
          findings: notes)
      }
      failure = "\(what) exited 0, but \(judgement.message)"
    case .failed(let exit, let tail, _): failure = "\(what) failed, exit \(exit):\n\(tail)"
    case .crashed(let signal, let tail):
      failure = "\(what) crashed\(signal.map { " with signal \($0)" } ?? ""):\n\(tail)"
    case .timedOut(let tail):
      failure =
        "\(what) hung: it hit its \(bound.seconds) s bound (\(bound.reason)), so the gate killed "
        + "its process tree:\n\(tail)"
    }
    return GateRunParts(
      tiers: [
        try TierResult(
          tier: .t1, verdict: .red, durationMilliseconds: milliseconds, testCounts: nil)
      ],
      findings: [
        try Finding(
          ruleID: BrownfieldRuleID.testFailed.rawValue, severity: .major, file: owner.root,
          line: nil, message: failure, failureScenario: nil)
      ] + notes)
  }

  private static func note(_ message: String) -> [Finding] {
    (try? Finding(
      ruleID: CheckRun.notRunRuleID, severity: .nit, file: ".", line: nil,
      message: "test-only: \(message)", failureScenario: nil)).map { [$0] } ?? []
  }

  /// A BLOCKED run: a test that never ran must never read as GREEN.
  static func notRun(_ reason: String) throws -> GateRunParts {
    GateRunParts(
      tiers: [
        try TierResult(tier: .t1, verdict: .blocked, durationMilliseconds: 0, testCounts: nil)
      ],
      findings: [
        try Finding(
          ruleID: CheckRun.notRunRuleID, severity: .minor, file: ".", line: nil,
          message: "test-only not run: \(reason)", failureScenario: nil)
      ])
  }
}

struct TestOnlyCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "test-only",
    abstract:
      "Compile and run 1 test through a brownfield area's test command, with no baseline or "
      + "prove: the cheap loop before a merge gate.")

  @Argument(help: "The test, as the area's filter takes it: <Target>/<Class>[/<method>] in Xcode.")
  var test: String

  @Option(help: "The area to run it in; defaults to the 1 area with a test command.")
  var area: String?

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let cwd = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let root =
      (try? await BrownfieldCheck.repositoryRoot(
        from: cwd, git: LiveGit(runner: LiveProcessRunner(), repositoryRoot: cwd.path))) ?? cwd
    try await GateRun.execute(root: root, format: output.format, command: "test-only") {
      context in
      let dependencies: TestOnlyCheck.Dependencies
      do throws(BrownfieldCheckSetupError) {
        dependencies = try await .live(root: root)
      } catch {
        return try TestOnlyCheck.notRun(error.reason)
      }
      return try await TestOnlyCheck.run(
        root: root, test: test, area: area, context: context, dependencies: dependencies)
    }
  }
}

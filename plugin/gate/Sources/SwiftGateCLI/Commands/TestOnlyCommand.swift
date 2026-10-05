import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// `test-only <id>`: 1 test through a brownfield area's own test command, narrowed to `id`, with
/// no baseline, prove or lint. It compiles what the test needs and runs it, so a fixer or worker
/// iterates on a compile or test failure in a fraction of a merge gate.
enum TestOnlyCheck {
  struct Dependencies: Sendable {
    let areas: [BrownfieldArea]
    let layout: BrownfieldStateLayout
    let trackedTree: TrackedTreeSnapshot
    let runner: any AreaCommandRunning
    let xcresults: any XcresultReader
    /// Per command run.
    let deadline: Duration

    /// The clone's config and state, and `/bin/sh` commands.
    static func live(root: URL) async throws(BrownfieldCheckSetupError) -> Dependencies {
      let merge = try await BrownfieldMergeCheck.Dependencies.live(root: root)
      return Dependencies(
        areas: merge.config.areas, layout: merge.layout, trackedTree: merge.trackedTree,
        runner: merge.runner, xcresults: LiveXcresultReader(runner: LiveProcessRunner()),
        deadline: BrownfieldMergeCheck.Dependencies.liveDeadline)
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
    let directory = resolved.root == "." ? root : root.appending(path: resolved.root)
    let request = AreaCommandRequest(
      area: owner.name, step: .testFiles, command: resolved.command,
      workingDirectory: directory.path(percentEncoded: false), deadline: dependencies.deadline,
      environment: AreaCacheEnvironment.make(
        area: owner, layout: dependencies.layout, tree: dependencies.trackedTree
      ).variables,
      junitPath: resolved.command.contains(junit) ? junit : nil)
    let (outcome, milliseconds) = await GateRun.timed { await dependencies.runner.run(request) }
    context.steps.record(
      .areaTest, tier: nil, milliseconds: milliseconds,
      verdict: outcome == .passed ? .green : .red, area: owner.name)

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
          ])
      }
      failure = "\(what) exited 0, but \(judgement.message)"
    case .failed(let exit, let tail, _): failure = "\(what) failed, exit \(exit):\n\(tail)"
    case .crashed(let signal, let tail):
      failure = "\(what) crashed\(signal.map { " with signal \($0)" } ?? ""):\n\(tail)"
    case .timedOut(let tail): failure = "\(what) timed out:\n\(tail)"
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
      ])
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

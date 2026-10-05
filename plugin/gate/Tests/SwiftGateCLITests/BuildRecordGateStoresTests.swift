import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

private struct FixedClock: BuildClock {
  let date: Date
  func now() -> Date { date }
}

/// `build record-gate` run from the user's checkout of a brownfield clone for a merge gate that
/// ran in the plan checkout, whose history line is in the plan checkout's own store.
@Suite("build record-gate reads the run history of every checkout")
struct BuildRecordGateStoresTests {
  /// A real repository whose common dir holds the harness config, with a linked plan checkout
  /// from `git worktree add`; both keep their runs under their own git dirs.
  struct Clone {
    let base: URL
    let user: URL
    let plan: URL

    init() async throws {
      base = TestTemporaryDirectory.root.appending(
        path: "swiftgate-record-gate-clone-\(UUID().uuidString)", directoryHint: .isDirectory
      ).resolvingSymlinksInPath()
      user = base.appending(path: "repo", directoryHint: .isDirectory)
      plan = base.appending(path: "repo-spec", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
      let runner = LiveProcessRunner(baseEnvironment: [
        "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
        "HOME": TestTemporaryDirectory.sharedHome.path,
        "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
        "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
      ])
      for arguments in [
        ["init", "-q", "-b", "main"], ["commit", "-q", "--allow-empty", "-m", "base"],
        ["worktree", "add", "-q", "-b", "spec", plan.path],
      ] {
        let output = try await runner.run(
          ProcessInvocation(
            executable: "git", arguments: arguments, workingDirectory: user.path,
            timeout: .seconds(30)))
        try #require(output.status.isSuccess, "git \(arguments): \(output.stderr.text)")
      }
      let config = user.appending(path: ".git/\(StateRootResolver.commonConfigFile)")
      try FileManager.default.createDirectory(
        at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(PresetScenario.brownfieldConfig.utf8).write(to: config)
    }

    func remove() { TestTemporaryDirectory.remove(base) }
  }

  /// The `gate.run` event a trial's merge gate wrote, for the command and finish time its
  /// history line recorded.
  struct GateRunEvent: Decodable {
    struct Payload: Decodable { let command: String }
    let runID: String
    let time: String
    let payload: Payload
  }

  /// A brownfield build run of the plan, held by the scenario's session.
  static func startBrownfieldRun(_ scenario: PresetScenario) async throws {
    try scenario.makeBrownfieldClone()
    try scenario.claimPlanned()
    let catalog = try await BuildPresetCatalog.load(root: scenario.checkout, git: scenario.git)
    let started = await scenario.start("brownfield", catalog: catalog)
    try #require(started.report != nil, "\(started.message)")
  }

  @Test(
    "record-gate from the user's checkout records the trial's GREEN merge gate run dc087158 that ran in the plan checkout — catches a record-gate BLOCKED for a gate whose history line is in another checkout's store"
  )
  func recordsThePlanCheckoutsRun() async throws {
    let scenario = PresetScenario()
    defer { scenario.shared.remove() }
    try await Self.startBrownfieldRun(scenario)
    let clone = try await Clone()
    defer { clone.remove() }
    let event = try JSONDecoder().decode(
      GateRunEvent.self, from: Fixture.data("RecordGate/merge-gate-run-event.json"))
    let report = try RunReportJSON.decode(Fixture.data("RecordGate/merge-gate-report.json"))
    let finishedAt = try Date(event.time, strategy: .iso8601)
    let planStore = RunStore(worktreeRoot: clone.plan)
    guard case .gitDir = planStore.state else {
      Issue.record("the plan checkout keeps its runs in the tree: \(planStore.state)")
      return
    }
    try planStore.record(report, finishedAt: finishedAt, command: event.payload.command)

    let result = await BuildRecordGateRun.run(
      slug: PresetScenario.plan, stage: .merge(task: "a"), runID: event.runID,
      session: PresetScenario.session, root: clone.user, git: scenario.git,
      clock: FixedClock(date: PresetScenario.startedAt))

    #expect(result.verdict == .green, "\(result.message)")
    #expect(result.report?.runId == "20261005T170620Z-dc087158")
    #expect(result.report?.tier == .merge)
    #expect(result.report?.verdict == .green)
  }

  @Test(
    "record-gate for a run in no checkout's history is BLOCKED and names each history file it read, the user's and the plan checkout's — catches a refusal that leaves the orchestrator guessing which checkout to run it from"
  )
  func refusalNamesEveryHistoryRead() async throws {
    let scenario = PresetScenario()
    defer { scenario.shared.remove() }
    try await Self.startBrownfieldRun(scenario)
    let clone = try await Clone()
    defer { clone.remove() }

    let result = await BuildRecordGateRun.run(
      slug: PresetScenario.plan, stage: .final, runID: "20260927T190000Z-0000dead",
      session: PresetScenario.session, root: clone.user, git: scenario.git,
      clock: FixedClock(date: PresetScenario.startedAt))

    #expect(result.verdict == .blocked)
    for checkout in [clone.user, clone.plan] {
      let file = RunStore(worktreeRoot: checkout).historyFile.standardizedFileURL.path
      #expect(result.message.contains(file), "\(result.message)")
    }
  }
}

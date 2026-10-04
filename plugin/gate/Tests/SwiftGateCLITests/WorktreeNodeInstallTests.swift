import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// A brownfield clone shaped like the memos trials: its captured `config.toml` (a pnpm `web` area
/// and a Go area at the root) and, under `web/`, a captured pnpm project.
private func memosLikeScenario() async throws -> PlanBranchScenario {
  var files: [String: Data] = ["go.mod": Data("module example.com/memos\n".utf8)]
  let pnpm = Fixture.directory.appending(path: "NodeInstall/pnpm", directoryHint: .isDirectory)
  for name in try FileManager.default.contentsOfDirectory(atPath: pnpm.path) {
    files["web/\(name)"] = try Data(contentsOf: pnpm.appending(path: name))
  }
  return try await PlanBranchScenario(
    config: try Fixture.text("BrownfieldTrial/memos-4-config.toml"), files: files)
}

/// Answers the package manager's cache-path question with `cache`, and every install with `install`.
private func installRunner(
  cache: String, install: @escaping @Sendable () throws(ProcessRunnerError) -> ProcessOutput
) -> FakeProcessRunner {
  FakeProcessRunner { invocation throws(ProcessRunnerError) in
    if invocation.arguments == ["store", "path"] {
      return ProcessOutput(status: .exited(0), stdout: cache + "\n")
    }
    return try install()
  }
}

private func installs(_ runner: FakeProcessRunner) -> [ProcessInvocation] {
  runner.invocations.filter { $0.arguments.first == "install" || $0.arguments.first == "ci" }
}

private func warmupRuns(_ log: MemoryEventLog) -> [WarmupRunEvent] {
  log.events.compactMap {
    guard case .warmupRun(let run) = $0.payload else { return nil }
    return run
  }
}

@Suite("a new brownfield worktree installs its node areas' dependencies")
struct WorktreeNodeInstallTests {
  @Test(
    "worktree create runs 1 frozen pnpm install in the new worktree's web directory with the area's shared caches, reports it and records a warmup.run install step, and runs nothing for the Go area at the root — catches a node area's worktree created without an install, or a non-node area getting one"
  )
  func createInstallsTheNodeArea() async throws {
    let scenario = try await memosLikeScenario()
    defer { scenario.remove() }
    let store = scenario.base.appending(path: "pnpm-store", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: store.appending(path: "index"))
    let runner = installRunner(cache: store.path) { ProcessOutput(status: .exited(0)) }
    let log = MemoryEventLog()

    let report = await scenario.create(
      install: .init(
        installer: LiveNodeDependencyInstaller(git: scenario.runner, installs: runner),
        events: { _ in log }))

    #expect(report.status == .created, "\(report.message)")
    let ran = installs(runner)
    #expect(ran.map(\.executable) == ["pnpm"])
    #expect(ran.map(\.arguments) == [["install", "--frozen-lockfile", "--prefer-offline"]])
    #expect(ran.map(\.workingDirectory) == [scenario.taskWorktree + "/web"])
    #expect(
      ran.first?.environmentOverlay["npm_config_store_dir"]
        == .some(scenario.common + "/swift-harness/caches/pnpm-store"))
    #expect(report.installs?.map(\.areas) == [["web"]])
    #expect(report.installs?.map(\.outcome) == [.passed])
    #expect(report.installs?.map(\.cache) == [.warm])
    #expect(report.message.contains("installed web"), "\(report.message)")
    let events = warmupRuns(log)
    #expect(events.map(\.step) == [.install])
    #expect(events.map(\.area) == ["web"])
    #expect(events.map(\.outcome) == [.passed])
  }

  @Test(
    "a frozen install that fails, or a package manager that isn't on PATH, leaves the worktree created and GREEN, with the failure as a report line — catches a failed install crashing worktree creation"
  )
  func failedInstallStillCreates() async throws {
    let output = try Fixture.text("NodeInstall/pnpm-outdated/output.txt")
    let cases: [(@Sendable () throws(ProcessRunnerError) -> ProcessOutput, WarmupOutcome, String)] =
      [
        (
          { ProcessOutput(status: .exited(1), stdout: output) }, .failed,
          "ERR_PNPM_OUTDATED_LOCKFILE"
        ),
        (
          { () throws(ProcessRunnerError) in
            throw .launchFailed(executable: "pnpm", reason: "not found on PATH")
          }, .notInstalled, "not found on PATH"
        ),
      ]
    for (install, outcome, detail) in cases {
      let scenario = try await memosLikeScenario()
      defer { scenario.remove() }
      let missing = scenario.base.appending(path: "no-store").path
      let log = MemoryEventLog()

      let report = await scenario.create(
        install: .init(
          installer: LiveNodeDependencyInstaller(
            git: scenario.runner, installs: installRunner(cache: missing, install: install)),
          events: { _ in log }))

      #expect(report.status == .created, "\(report.message)")
      #expect(report.verdict == .green)
      #expect(FileManager.default.fileExists(atPath: scenario.taskWorktree + "/web/package.json"))
      #expect(report.installs?.map(\.outcome) == [outcome])
      #expect(report.installs?.map(\.cache) == [.cold])
      #expect(report.installs?.first?.detail?.contains(detail) == true, "\(report.installs ?? [])")
      #expect(report.message.contains("web's install"), "\(report.message)")
      #expect(warmupRuns(log).map(\.outcome) == [outcome])
    }
  }

  @Test(
    "run checkout create installs the node area in the plan checkout too — catches a contract commit built in a checkout with no node_modules"
  )
  func planCheckoutInstalls() async throws {
    let scenario = try await memosLikeScenario()
    defer { scenario.remove() }
    _ = try await scenario.git("worktree", "remove", scenario.checkout)
    let runner = installRunner(cache: scenario.base.path) { ProcessOutput(status: .exited(0)) }
    let log = MemoryEventLog()

    let report = await RunCheckoutRun.create(
      slug: PlanBranchScenario.slug, session: PlanBranchScenario.session, root: scenario.user,
      runner: scenario.runner,
      install: .init(
        installer: LiveNodeDependencyInstaller(git: scenario.runner, installs: runner),
        events: { _ in log }))

    #expect(report.status == .created, "\(report.message)")
    #expect(installs(runner).map(\.workingDirectory) == [scenario.checkout + "/web"])
    #expect(report.installs?.map(\.outcome) == [.passed])
    #expect(warmupRuns(log).map(\.step) == [.install])
  }
}

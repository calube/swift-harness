import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// A throwaway brownfield clone holding the third price-tracker trial's `PLAN.md`, `config.toml`
/// and the files its contract commit touched, at the base and at the contract, with the plan
/// branch checked out beside it as the plan checkout.
private struct SeamClone {
  static let slug = "spec"
  static let contract = "tracker-contract"
  static let planBranch = "swift-harness/spec"
  static let appFile = "App/TimedBuildStarterApp.swift"
  static let trial = Fixture.directory.appending(
    path: "BrownfieldTrial", directoryHint: .isDirectory)

  let parent: URL
  let root: URL
  let checkout: URL
  let runner = LiveProcessRunner(baseEnvironment: [
    "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
    "HOME": TestTemporaryDirectory.sharedHome.path,
    "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
  ])

  init() async throws {
    parent = try TestTemporaryDirectory.make("swiftgate-seam").resolvingSymlinksInPath()
    root = parent.appending(path: "repo", directoryHint: .isDirectory)
    checkout = parent.appending(path: "repo-\(Self.slug)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try await git(in: root, "init", "-q", "-b", "main")
    try await git(in: root, "config", "commit.gpgsign", "false")
    try copy("base", into: root)
    try await git(in: root, "add", "-A")
    try await git(in: root, "commit", "-q", "-m", "base")
    let state = root.appending(path: ".git/swift-harness", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: planDirectory, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: Self.trial.appending(path: "price-tracker-3-config.toml"),
      to: state.appending(path: "config.toml"))
    try FileManager.default.copyItem(
      at: Self.trial.appending(path: "price-tracker-3-PLAN.md"),
      to: planDirectory.appending(path: "PLAN.md"))
    try await git(in: root, "branch", Self.planBranch)
    try await git(in: root, "worktree", "add", "-q", checkout.path, Self.planBranch)
  }

  func remove() { TestTemporaryDirectory.remove(parent) }

  var gitClient: LiveGit { LiveGit(runner: runner, repositoryRoot: root.path) }

  var planDirectory: URL {
    root.appending(path: ".git/swift-harness/plans/\(Self.slug)", directoryHint: .isDirectory)
  }

  /// Copies the fixture folder `folder` (`base`, `contract` or `seam`, or a path under
  /// `BrownfieldTrial` holding a slash) over `destination`.
  func copy(_ folder: String, into destination: URL) throws {
    let source = Self.trial.appending(
      path: folder.contains("/") ? folder : "price-tracker-3-contract/\(folder)",
      directoryHint: .isDirectory)
    let walker = try #require(
      FileManager.default.enumerator(at: source, includingPropertiesForKeys: nil))
    for case let url as URL in walker where !url.hasDirectoryPath {
      let relative = String(
        url.standardizedFileURL.path.dropFirst(source.standardizedFileURL.path.count + 1))
      let target = destination.appending(path: relative)
      try FileManager.default.createDirectory(
        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? FileManager.default.removeItem(at: target)
      try FileManager.default.copyItem(at: url, to: target)
    }
  }

  /// Commits `folder` in the plan checkout and records a GREEN `check slice` run of it.
  func land(_ folder: String, runID: String) async throws {
    let base = try await git(in: root, "rev-parse", "main")
    try copy(folder, into: checkout)
    try await git(in: checkout, "add", "-A")
    try await git(in: checkout, "commit", "-q", "-m", "contract: \(folder)")
    let head = try await git(in: checkout, "rev-parse", "HEAD")
    let report = try RunReport(
      runID: runID, durationMilliseconds: 43_778,
      tiers: [
        try TierResult(tier: .t1, verdict: .green, durationMilliseconds: 43_690, testCounts: nil)
      ],
      findings: [])
    try RunStore(worktreeRoot: checkout).record(
      report, finishedAt: Date(timeIntervalSince1970: 1_790_000_000), command: "check slice",
      headCommit: head, base: base)
  }

  func importPlan(contractRun: String) async -> PlanImportReport {
    await PlanImportRun.run(
      slug: Self.slug, root: root, git: gitClient,
      contract: PlanImportRun.Contract(task: Self.contract, runID: contractRun))
  }

  @discardableResult
  func git(in directory: URL, _ arguments: String...) async throws -> String {
    let output = try await runner.run(
      ProcessInvocation(
        executable: "git", arguments: arguments, workingDirectory: directory.path,
        timeout: .seconds(30)))
    try #require(output.status.isSuccess, "git \(arguments): \(output.stderr.text)")
    return output.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

@Suite("plan import of a contract missing its app seam")
struct PlanImportContractSeamTests {
  @Test(
    "the trial's contract commit, GREEN but without the app file its Writes names, imports with the contract pending naming that file and the missing -harness-scenario seam; the seam commit leaves it pending on its refresh row's unpinned bottom marker, and a view pinning that marker lands it — catches the trial's contract accepted while every flow read the live service, or a refresh drag left with nothing to end on"
  )
  func contractWithoutSeamStaysPending() async throws {
    let clone = try await SeamClone()
    defer { clone.remove() }
    try await clone.land("contract", runID: "20261005T055628Z-0c95049d")

    let report = await clone.importPlan(contractRun: "20261005T055628Z-0c95049d")

    #expect(report.status == .imported, "\(report.message)")
    #expect(report.verdict == .red, "\(report.message)")
    #expect(report.contract?.status == .pending, "\(report.message)")
    let message = report.contract?.message ?? ""
    #expect(message.contains(ContractLanding.unlandedWriteRuleID), "\(message)")
    #expect(message.contains("`\(SeamClone.appFile)`"), "\(message)")
    #expect(message.contains(ContractLanding.scenarioSeamRuleID), "\(message)")

    try await clone.land("seam", runID: "20261005T061106Z-6b7b7d78")
    let seamed = await clone.importPlan(contractRun: "20261005T061106Z-6b7b7d78")
    let unpinned = seamed.contract?.message ?? ""
    #expect(seamed.contract?.status == .pending, "\(seamed.message)")
    #expect(!unpinned.contains(ContractLanding.scenarioSeamRuleID), "\(unpinned)")
    #expect(unpinned.contains(ContractLanding.refreshMarkerRuleID), "\(unpinned)")
    #expect(unpinned.contains("req-refresh-last-updated"), "\(unpinned)")

    try await clone.land("price-tracker-5-watchlist/fixer", runID: "20261005T062000Z-5f1e2d3c")
    let landed = await clone.importPlan(contractRun: "20261005T062000Z-5f1e2d3c")
    #expect(landed.contract?.status == .done, "\(landed.message)")
    #expect(landed.verdict == .green, "\(landed.message)")
  }
}

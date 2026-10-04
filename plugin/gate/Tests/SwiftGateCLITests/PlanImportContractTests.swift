import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

private struct PinnedClock: BuildClock {
  let date: Date
  func now() -> Date { date }
}

/// A throwaway brownfield clone holding the fourth memos trial's `PLAN.md` and `config.toml`, with
/// its plan branch checked out beside it as the run skill's plan checkout, where the contract is
/// committed and gated. Everything sits in 1 temp directory, so nothing reaches this checkout's
/// common dir.
private struct ContractClone {
  static let slug = "spec"
  static let session = "a7e1495d-74fe-474b-baf4-ad95d6f7bc65"
  static let contract = "share-view-limit-contract"
  static let planBranch = "swift-harness/spec"

  let parent: URL
  let root: URL
  let checkout: URL
  let runner = LiveProcessRunner(baseEnvironment: [
    "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
    "HOME": FileManager.default.temporaryDirectory.path,
    "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
  ])

  init() async throws {
    parent = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-contract-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    root = parent.appending(path: "memos", directoryHint: .isDirectory)
    checkout = parent.appending(path: "memos-\(Self.slug)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try await git(in: root, "init", "-q", "-b", "main")
    try await git(in: root, "config", "commit.gpgsign", "false")
    try Data("package store\n".utf8).write(to: root.appending(path: "store.go"))
    try await git(in: root, "add", "-A")
    try await git(in: root, "commit", "-q", "-m", "base")
    let trial = Fixture.directory.appending(path: "BrownfieldTrial", directoryHint: .isDirectory)
    let state = root.appending(path: ".git/swift-harness", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: planDirectory, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: trial.appending(path: "memos-4-config.toml"), to: state.appending(path: "config.toml"))
    try FileManager.default.copyItem(
      at: trial.appending(path: "memos-4-PLAN.md"), to: planDirectory.appending(path: "PLAN.md"))
    try await git(in: root, "branch", Self.planBranch)
    try await git(in: root, "worktree", "add", "-q", checkout.path, Self.planBranch)
  }

  func remove() { try? FileManager.default.removeItem(at: parent) }

  var gitClient: LiveGit { LiveGit(runner: runner, repositoryRoot: root.path) }

  var planDirectory: URL {
    root.appending(path: ".git/swift-harness/plans/\(Self.slug)", directoryHint: .isDirectory)
  }

  /// Commits the contract on the plan branch in the plan checkout; returns the commit and its base.
  func landContract() async throws -> (commit: String, base: String) {
    let base = try await git(in: checkout, "rev-parse", "HEAD")
    try Data("package store\n\ntype MemoShare struct{ ViewLimit *int32 }\n".utf8).write(
      to: checkout.appending(path: "store.go"))
    try await git(in: checkout, "commit", "-q", "-am", "feat(store): declare view limits")
    return (try await git(in: checkout, "rev-parse", "HEAD"), base)
  }

  /// Records a `check slice` run in the plan checkout's history through the run store.
  func gate(_ verdict: Verdict, head: String, base: String, runID: String) throws {
    let report = try RunReport(
      runID: runID, durationMilliseconds: 27_629,
      tiers: [
        try TierResult(tier: .t1, verdict: verdict, durationMilliseconds: 27_498, testCounts: nil)
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

  func ledger() throws -> Ledger {
    try LedgerJSON.decode(Data(contentsOf: planDirectory.appending(path: "ledger.json")))
  }

  var preBuildReturn: URL {
    planDirectory.appending(path: "returns/\(Self.contract).json")
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

@Suite("plan import of a landed contract")
struct PlanImportContractTests {
  @Test(
    "importing with the contract's GREEN gate run sets the contract done with a return citing its commit, and the build's dependents read it — catches the contract task left pending after import"
  )
  func greenContractIsDone() async throws {
    let clone = try await ContractClone()
    defer { clone.remove() }
    let (commit, base) = try await clone.landContract()
    let runID = "20261004T141540Z-be184a1a"
    try clone.gate(.green, head: commit, base: base, runID: runID)

    let report = await clone.importPlan(contractRun: runID)

    #expect(report.status == .imported, "\(report.message)")
    #expect(report.verdict == .green, "\(report.message)")
    #expect(report.contract?.status == .done)
    #expect(report.contract?.commit == commit)
    let statuses = Dictionary(
      uniqueKeysWithValues: try clone.ledger().tasks.map { ($0.id, $0.status) })
    #expect(statuses[ContractClone.contract] == .done)
    #expect(statuses["share-view-limit-store"] == .pending)
    let recorded = try TaskReturnJSON.decode(Data(contentsOf: clone.preBuildReturn))
    #expect(recorded.commits == [commit])
    #expect(recorded.gate == TaskReturn.Gate(tier: .slice, verdict: .green, runID: runID))

    #expect(
      await PlanLockRun.claim(
        slug: ContractClone.slug, session: ContractClone.session, git: clone.gitClient
      )
      .verdict == .green)
    let catalog = try await BuildPresetCatalog.load(root: clone.root, git: clone.gitClient)
    let started = await BuildStartRun.run(
      slug: ContractClone.slug, presetName: BuildPresetCatalog.brownfieldPresetName,
      session: ContractClone.session, catalog: catalog, git: clone.gitClient,
      clock: PinnedClock(date: Date(timeIntervalSince1970: 1_790_000_100)), suffix: 0xbee)
    let run = try #require(started.report?.runId, "\(started.message)")
    let notes = ContextPackTaskReturn.notes(
      forTask: ContractClone.contract, buildRun: run, planDirectory: clone.planDirectory)
    #expect(notes == .success(recorded.notes))
  }

  @Test(
    "importing with a RED contract gate run leaves the contract pending and reports the run — catches import marking it done with a RED gate"
  )
  func redContractStaysPending() async throws {
    let clone = try await ContractClone()
    defer { clone.remove() }
    let (commit, base) = try await clone.landContract()
    let runID = "20261004T124744Z-9d7ec113"
    try clone.gate(.red, head: commit, base: base, runID: runID)

    let report = await clone.importPlan(contractRun: runID)

    #expect(report.status == .imported, "\(report.message)")
    #expect(report.verdict == .red)
    #expect(report.contract?.status == .pending)
    #expect(report.contract?.message.contains(runID) == true)
    #expect(report.contract?.message.contains("RED") == true)
    let contract = try clone.ledger().tasks.first { $0.id == ContractClone.contract }
    #expect(contract?.status == .pending)
    #expect(!FileManager.default.fileExists(atPath: clone.preBuildReturn.path))
  }

  @Test(
    "importing with a contract task PLAN.md doesn't name writes nothing — catches a typo recorded as a done task"
  )
  func unknownContractIsInvalid() async throws {
    let clone = try await ContractClone()
    defer { clone.remove() }
    let report = await PlanImportRun.run(
      slug: ContractClone.slug, root: clone.root, git: clone.gitClient,
      contract: PlanImportRun.Contract(
        task: "share-view-limit-contracts", runID: "20261004T141540Z-be184a1a"))

    #expect(report.status == .invalid)
    #expect(report.message.contains("share-view-limit-contracts"))
    #expect(
      !FileManager.default.fileExists(
        atPath: clone.planDirectory.appending(path: "ledger.json").path))
  }
}

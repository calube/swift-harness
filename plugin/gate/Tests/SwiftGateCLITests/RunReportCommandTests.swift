import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

@Suite("swiftgate run report")
struct RunReportCommandTests {
  @Test(
    "run report reads each checked return under the build run's returns/ and names the task whose review fell back and why — catches a report that says none, or no reason, when diff-risk didn't answer"
  )
  func reportReadsReturnsForReviewFallbacks() async throws {
    let clone = try await TemporaryClone(fixture: "usememos-memos")
    defer { clone.remove() }
    _ = try await DiscoverCommand.apply(
      directory: clone.root, edits: [],
      dependencies: clone.dependencies(readers: EcosystemReaders.all))
    let git = LiveGit(runner: clone.runner, repositoryRoot: clone.root.path)
    let store = try await BuildRunStore.create(
      plan: "spec", presetName: "brownfield", preset: Discover.brownfieldPreset,
      startedAt: Date(timeIntervalSince1970: 0), git: git, suffix: 1)
    let task = "share-view-limit-web"
    let at = Date(timeIntervalSince1970: 10)
    try await store.append(.transition(.init(task: task, from: .pending, to: .inProgress, at: at)))
    try await store.append(.transition(.init(task: task, from: .inProgress, to: .blocked, at: at)))
    let returns = URL(filePath: store.layout.directory + "/returns", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: returns, withIntermediateDirectories: true)
    try Fixture.data("BuildReturn/memos-4/\(task).json")
      .write(to: returns.appending(path: "\(task).json"))

    let outcome = await BrownfieldRunReportRun.write(
      slug: "spec", planBranch: nil, base: "main", root: clone.root, runner: clone.runner)

    let report = try #require(outcome.report, "\(outcome.message)")
    #expect(
      report.reviewFallbacks.items == [
        "\(task) (blocked): classified review ran at medium, because diff-risk gave no level: "
          + "the clone's config has no [judge] section"
      ])
  }

  @Test(
    "run report reads the newest qa run over every row from the checkout's runs for a plan with a validation table, and leads with how many rows it verified — catches a final GREEN that hides that no validation row ran"
  )
  func reportNamesUnverifiedValidation() async throws {
    let clone = try await TemporaryClone(fixture: "usememos-memos")
    defer { clone.remove() }
    _ = try await DiscoverCommand.apply(
      directory: clone.root, edits: [],
      dependencies: clone.dependencies(readers: EcosystemReaders.all))
    let git = LiveGit(runner: clone.runner, repositoryRoot: clone.root.path)
    _ = try await BuildRunStore.create(
      plan: "spec", presetName: "brownfield", preset: Discover.brownfieldPreset,
      startedAt: Date(timeIntervalSince1970: 0), git: git, suffix: 1)
    let plan = try PlanStateLayout(commonDirectory: try await git.commonDirectory()).plan("spec")
    try Fixture.data("QA/aidoku-validation/validation.json")
      .write(to: URL(filePath: plan.directory).appending(path: ValidationTable.fileName))
    let runID = "20261004T213430Z-5250c2ac"
    let qa = RunStore(worktreeRoot: clone.root).state
      .url(RunLayout.runDirectory(for: runID) + QAReport.directory, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: qa, withIntermediateDirectories: true)
    try Fixture.data("QA/aidoku-validation/final-report.json")
      .write(to: qa.appending(path: QAReport.fileName))

    let outcome = await BrownfieldRunReportRun.write(
      slug: "spec", planBranch: nil, base: "main", root: clone.root, runner: clone.runner)

    let report = try #require(outcome.report, "\(outcome.message)")
    #expect(report.validation == .init(runID: runID, verdict: .green, rows: 3, verified: 0))
    #expect(report.text.contains("validation: 0 of 3 rows verified"))
  }

  @Test(
    "run report rewrites the plan's newest build run's report page, which reads done once build finish recorded the end — catches a brownfield run whose saved page is a mid-run snapshot"
  )
  func reportRewritesTheRunPage() async throws {
    let clone = try await TemporaryClone(fixture: "usememos-memos")
    defer { clone.remove() }
    _ = try await DiscoverCommand.apply(
      directory: clone.root, edits: [],
      dependencies: clone.dependencies(readers: EcosystemReaders.all))
    let git = LiveGit(runner: clone.runner, repositoryRoot: clone.root.path)
    let store = try await BuildRunStore.create(
      plan: "spec", presetName: "brownfield", preset: Discover.brownfieldPreset,
      startedAt: Date(timeIntervalSince1970: 0), git: git, suffix: 1)
    try await store.append(.finish(.init(at: Date(timeIntervalSince1970: 60))))

    let outcome = await BrownfieldRunReportRun.write(
      slug: "spec", planBranch: nil, base: "main", root: clone.root, runner: clone.runner,
      pluginRoot: Fixture.checkoutRoot, now: Date(timeIntervalSince1970: 120))

    let page = try #require(outcome.runReport, "\(outcome.runReportNote ?? outcome.message)")
    #expect(page.hasSuffix("reports/\(store.runID)/index.html"), "\(page)")
    let url = page.hasPrefix("/") ? URL(filePath: page) : clone.root.appending(path: page)
    let html = try String(contentsOf: url, encoding: .utf8)
    let view = try #require(
      JSONSerialization.jsonObject(with: Data(try ReportCommandTests.dataBlock(html).utf8))
        as? [String: Any])
    #expect((view["run"] as? [String: Any])?["state"] as? String == "done")
    #expect((view["run"] as? [String: Any])?["snapshotAt"] is NSNull)
  }
}

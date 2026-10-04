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
}

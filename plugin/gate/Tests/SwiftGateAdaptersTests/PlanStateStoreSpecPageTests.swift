import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("PlanStateStore reads a spec-page plan")
struct PlanStateStoreSpecPageTests {
  @Test(
    "a spec-page plan's store decodes its plan.json and places the page in that plan's own directory — catches a page path resolved outside the plan whose lock guards it"
  )
  func pageSitsInThePlanDirectory() async throws {
    let common = FileManager.default.temporaryDirectory.appending(
      path: "swiftgate-spec-page-store-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: common) }
    let slug = "2026-09-28-reading-list"
    let plan = try PlanStateLayout(commonDirectory: common.path).plan(slug)
    try FileManager.default.createDirectory(
      atPath: plan.directory, withIntermediateDirectories: true)
    try PlanFileJSON.encode(PlanFile.seedSpecPage(slug: slug))
      .write(to: URL(filePath: plan.planFile))

    let store = try await PlanStateStore.locate(
      slug: slug, git: FakeGit(commonDirectory: common.path))
    let page = try #require(try store.planFile().specPageSource)
    #expect(store.specPageFile(page) == plan.directory + "/spec-page.md")
  }
}

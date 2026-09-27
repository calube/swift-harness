import SwiftGateDomain
import Testing

@Suite("module-graph dump")
struct ModuleGraphDumpTests {
  private static func graph() throws -> ModuleGraph {
    try ModuleGraph(packages: [
      PackageManifest(
        name: "Feed", path: "Packages/Feed", remoteDependencies: ["swift-composable-architecture"],
        targets: [
          PackageTarget(
            name: "FeedClient", type: .library, path: "Packages/Feed/Sources/FeedClient"),
          PackageTarget(
            name: "FeedCore", type: .library, path: "Packages/Feed/Sources/FeedCore",
            targetDependencies: ["FeedClient"], productDependencies: ["ComposableArchitecture"]),
          PackageTarget(
            name: "FeedCoreTests", type: .test, path: "Packages/Feed/Tests/FeedCoreTests",
            targetDependencies: ["FeedCore"]),
        ])
    ])
  }

  @Test(
    "the dump is the session's module map followed by one edge per target dependency, external products included — catches a dump that drops the edges a decomposer orders tasks by"
  )
  func mapThenEdges() throws {
    #expect(
      ModuleGraphDump.lines(try Self.graph()) == [
        "Modules by package (role, kind):",
        "- Feed: FeedClient (client, client), FeedCore (core, feature)",
        "FeedCore -> ComposableArchitecture",
        "FeedCore -> FeedClient",
        "FeedCoreTests -> FeedCore",
      ])
  }

  @Test(
    "the dump's module lines are the ones SessionStart renders — catches the two drifting apart so a pack's graph disagrees with the session's"
  )
  func sameMapAsSessionStart() throws {
    let graph = try Self.graph()
    let session = SessionContext.render(
      SessionContext.Inputs(
        projectName: "Feed", modules: SessionContext.moduleEntries(of: graph), xcode: nil,
        plans: .none, notes: []))
    let mapLines = ModuleGraphDump.lines(graph).filter { !$0.contains(" -> ") }
    #expect(mapLines.count == 2)
    for line in mapLines {
      #expect(session.contains(line), "\(line)")
    }
  }
}

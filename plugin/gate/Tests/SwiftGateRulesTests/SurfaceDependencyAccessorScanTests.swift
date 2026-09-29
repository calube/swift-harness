import SwiftGateDomain
import SwiftGateRules
import Testing

@Suite("surface-check body scan: dependency accessors")
struct SurfaceDependencyAccessorScanTests {
  private static let accessor = """
    extension DependencyValues {
      var feedClient: FeedClient {
        get { self[FeedClient.self] }
        set { self[FeedClient.self] = newValue }
      }
    }
    """

  private static func outcomes(
    _ text: String, parent: SurfaceParentIndex = SurfaceParentIndex(functions: [], types: []),
    commitTypes: Set<String> = []
  ) -> [SurfaceJudgement.Outcome] {
    SurfaceBodyScan.judge(
      SurfaceFileChange(path: "Sources/App/Dependencies.swift", parentText: nil, commitText: text),
      parent: parent, commitTypes: commitTypes
    ).map(\.outcome)
  }

  @Test(
    "the commit's declared types are every type any added or changed file declares, and none from a deleted file — catches a key declared beside the accessor's file judged undeclared"
  )
  func declaredTypesSpanTheCommit() {
    let types = SurfaceBodyScan.declaredTypes(in: [
      SurfaceFileChange(
        path: "Sources/App/FeedClient.swift", parentText: nil,
        commitText: "struct FeedClient {}\nenum Mode {}"),
      SurfaceFileChange(
        path: "Sources/App/Store.swift", parentText: "final class Store {}",
        commitText: "final class Store {}\nactor Cache {}"),
      SurfaceFileChange(
        path: "Sources/App/Old.swift", parentText: "struct Gone {}", commitText: nil),
    ])

    #expect(types == ["FeedClient", "Mode", "Store", "Cache"])
  }

  @Test(
    "a wired accessor is a stub when the commit or the parent declares its key, and names the key otherwise — catches a wired accessor passing on a key nothing declares"
  )
  func keyMustBeDeclared() {
    let wired = SurfaceJudgement.Outcome.stub(.wiresDependency)
    let undeclared = SurfaceJudgement.Outcome.behaviour(
      .undeclaredDependencyKey(key: "FeedClient"))

    #expect(Self.outcomes(Self.accessor, commitTypes: ["FeedClient"]) == [wired, wired])
    #expect(
      Self.outcomes(Self.accessor, parent: SurfaceParentIndex(functions: [], types: ["FeedClient"]))
        == [wired, wired])
    #expect(Self.outcomes(Self.accessor, commitTypes: ["Feed"]) == [undeclared, undeclared])
  }

  @Test(
    "a shorthand getter and a qualified key wire too, and a labelled or 2-argument subscript doesn't — catches a subscript that computes a value passing as the key's slot"
  )
  func subscriptShapes() {
    let outcomes = Self.outcomes(
      """
      extension Dependencies.DependencyValues {
        var feedClient: FeedClient { self[Clients.FeedClient.self] }
        var labelled: FeedClient { self[key: FeedClient.self] }
        var pair: FeedClient { self[FeedClient.self, Mode.self] }
        var instance: FeedClient { self[client.self] }
      }
      """, commitTypes: ["FeedClient"])

    #expect(
      outcomes == [
        .stub(.wiresDependency),
        .behaviour(.notAStub(excerpt: "self[key: FeedClient.self]")),
        .behaviour(.notAStub(excerpt: "self[FeedClient.self, Mode.self]")),
        .behaviour(.notAStub(excerpt: "self[client.self]")),
      ])
  }
}

import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("PackageManifest")
struct PackageManifestTests {
  private let root = Fixture.repositoryRoot

  @Test(
    "describe output becomes repository-relative paths — catches changed files never matching a target"
  )
  func repositoryRelativePaths() throws {
    let manifest = try PackageManifest(
      describeJSON: Fixture.describe("APIClient"), repositoryRoot: root)

    #expect(manifest.name == "APIClient")
    #expect(manifest.path == "examples/SampleApp/Packages/APIClient")
    #expect(manifest.localDependencyPaths == ["examples/SampleApp/Packages/HTTPClient"])
    #expect(
      manifest.targets.map(\.path).sorted() == [
        "examples/SampleApp/Packages/APIClient/Sources/APIClient",
        "examples/SampleApp/Packages/APIClient/Sources/APIClientLive",
        "examples/SampleApp/Packages/APIClient/Tests/APIClientLiveTests",
      ])
  }

  @Test(
    "targets keep their type and declared dependencies — catches test targets treated as libraries")
  func targetsAndDependencies() throws {
    let manifest = try PackageManifest(
      describeJSON: Fixture.describe("APIClient"), repositoryRoot: root)
    let live = try #require(manifest.target(named: "APIClientLive"))
    let tests = try #require(manifest.target(named: "APIClientLiveTests"))

    #expect(live.type == .library)
    #expect(live.targetDependencies == ["APIClient"])
    #expect(live.productDependencies == ["HTTPClient", "Dependencies"])
    #expect(tests.type == .test)
    #expect(manifest.products["APIClientLive"] == ["APIClientLive"])
  }

  @Test("a trailing slash on the root is accepted — catches a spurious outside-repository error")
  func rootWithTrailingSlash() throws {
    let manifest = try PackageManifest(
      describeJSON: Fixture.describe("GameEngine"), repositoryRoot: root + "/")
    #expect(manifest.path == "examples/SampleApp/Packages/GameEngine")
  }

  @Test("a package outside the repository is rejected — catches silently scoping the wrong tree")
  func packageOutsideRepository() throws {
    let data = try Fixture.describe("GameEngine")
    #expect(
      throws: PackageManifestError.pathOutsideRepository(
        "/REPO/examples/SampleApp/Packages/GameEngine")
    ) {
      _ = try PackageManifest(describeJSON: data, repositoryRoot: "/REP")
    }
  }

  @Test("non-describe JSON is rejected with a reason — catches an empty graph that selects nothing")
  func malformedJSON() {
    #expect {
      _ = try PackageManifest(describeJSON: Data(#"{"name":"X"}"#.utf8), repositoryRoot: root)
    } throws: { error in
      guard case .malformedDescription(let detail)? = error as? PackageManifestError else {
        return false
      }
      return detail.contains("path") || detail.contains("targets")
    }
  }
}

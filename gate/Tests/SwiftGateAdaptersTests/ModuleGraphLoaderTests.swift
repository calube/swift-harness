import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("ModuleGraphLoader")
struct ModuleGraphLoaderTests {
  private func makeTree(_ files: [String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-graph-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    for path in files {
      let url = root.appending(path: path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data().write(to: url)
    }
    return root
  }

  private func config(packages: [String]) throws -> Config {
    try Config(
      xcode: "26.2", appScheme: "App", packages: packages,
      simulator: SimulatorConfig(device: "iPhone 17", os: "26.2"))
  }

  @Test(
    "package globs expand per path segment to directories holding a Package.swift — catches a package silently left out of the graph"
  )
  func expandsGlobs() throws {
    let root = try makeTree([
      "Packages/Feed/Package.swift", "Packages/Pay/Package.swift", "Packages/Notes/README.md",
      "Tools/Lint/Package.swift", "Packages/Feed/.build/checkouts/X/Package.swift",
    ])
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(
      try PackageDirectories.resolve(globs: ["Packages/*", "Tools/Lint"], root: root)
        == ["Packages/Feed", "Packages/Pay", "Tools/Lint"])
  }

  @Test(
    "a glob matching no package is a RED config error — catches a typo'd glob scoping nothing and passing"
  )
  func unmatchedGlob() throws {
    let root = try makeTree(["Packages/Feed/Package.swift"])
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(throws: ModuleGraphLoadError.unmatchedGlob("Pakages/*")) {
      try PackageDirectories.resolve(globs: ["Packages/*", "Pakages/*"], root: root)
    }
    #expect(ModuleGraphLoadError.unmatchedGlob("x").verdict == .red)
  }

  @Test(
    "describes every matched package into one graph — catches scopes built from a subset of packages"
  )
  func loadsGraph() async throws {
    let root = try makeTree(
      Fixture.samplePackages.map { "examples/SampleApp/Packages/\($0)/Package.swift" })
    defer { try? FileManager.default.removeItem(at: root) }
    let swiftPM = FakeSwiftPM { directory throws(SwiftPMError) in
      let name = String(directory.split(separator: "/").last ?? "")
      do {
        return try PackageManifest(
          describeJSON: Fixture.describe(name), repositoryRoot: Fixture.repositoryRoot)
      } catch {
        throw .unparseableOutput(command: "describe", detail: "\(error)")
      }
    }

    let graph = try await ModuleGraphLoader(swiftPM: swiftPM, root: root)
      .load(config: config(packages: ["examples/SampleApp/Packages/*"]))

    #expect(graph.packages.count == 5)
    #expect(Set(swiftPM.described) == Set(graph.packages.map(\.path)))
    #expect(
      graph.scope(
        forFile:
          "examples/SampleApp/Packages/HTTPClient/Sources/HTTPClientLive/HTTPClientLive.swift"
      ) == ModuleScope(module: "HTTPClientLive", role: .clientLive, kind: .client))
  }

  @Test(
    "a describe failure is BLOCKED and a local dependency outside the globs is RED — catches a partial graph passing as complete"
  )
  func failures() async throws {
    let root = try makeTree(["examples/SampleApp/Packages/APIClient/Package.swift"])
    defer { try? FileManager.default.removeItem(at: root) }
    let failing = FakeSwiftPM { _ throws(SwiftPMError) in
      throw .unparseableOutput(command: "describe", detail: "boom")
    }
    let partial = FakeSwiftPM { _ throws(SwiftPMError) in
      do {
        return try PackageManifest(
          describeJSON: Fixture.describe("APIClient"), repositoryRoot: Fixture.repositoryRoot)
      } catch {
        throw .unparseableOutput(command: "describe", detail: "\(error)")
      }
    }
    let config = try config(packages: ["examples/SampleApp/Packages/*"])

    await #expect {
      _ = try await ModuleGraphLoader(swiftPM: failing, root: root).load(config: config)
    } throws: { ($0 as? ModuleGraphLoadError)?.verdict == .blocked }
    await #expect {
      _ = try await ModuleGraphLoader(swiftPM: partial, root: root).load(config: config)
    } throws: { ($0 as? ModuleGraphLoadError)?.verdict == .red }
  }
}

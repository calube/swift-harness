import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

/// `LiveSwiftPM` with a manifest cache: `describe` and `dump-package` answers are reused until
/// the package's `Package.swift` or `Package.resolved` changes.
@Suite("LiveSwiftPM manifest cache")
struct ManifestCacheTests {
  private static let package = "examples/SampleApp/Packages/GameEngine"

  private final class Flag: Sendable {
    let value = Mutex(false)
  }

  private struct Project {
    let root: URL
    let runner: FakeProcessRunner
    let failNext = Flag()

    init() throws {
      root = FileManager.default.temporaryDirectory
        .appending(path: "swiftgate-manifests-\(UUID().uuidString)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(
        at: root.appending(path: ManifestCacheTests.package), withIntermediateDirectories: true)
      let describe = try Fixture.text("SwiftPM/describe-GameEngine.json")
        .replacingOccurrences(of: Fixture.repositoryRoot, with: root.path)
      let dump = try Fixture.text("SwiftPM/dump-package-main-actor-core.json")
      let failNext = self.failNext
      runner = FakeProcessRunner { invocation in
        let fail = failNext.value.withLock { flag in
          defer { flag = false }
          return flag
        }
        if fail {
          return ProcessOutput(status: .exited(1), stderr: "error: manifest parse failed")
        }
        return ProcessOutput(
          status: .exited(0), stdout: invocation.arguments.contains("describe") ? describe : dump)
      }
      try write("Package.swift", "// swift-tools-version: 6.2\n")
    }

    func write(_ file: String, _ text: String) throws {
      try Data(text.utf8).write(to: root.appending(path: "\(ManifestCacheTests.package)/\(file)"))
    }

    /// A fresh adapter per call, as every hook and command is a fresh process.
    func describe() async throws -> PackageManifest {
      try await LiveSwiftPM(
        runner: runner, repositoryRoot: root.path,
        manifestCache: root.appending(path: ".harness/cache/manifests")
      ).describe(packageDirectory: ManifestCacheTests.package)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
  }

  @Test(
    "an unchanged package is described once across processes — catches every hook and pre-commit paying seconds of swift package describe"
  )
  func reusesAnswer() async throws {
    let project = try Project()
    defer { project.remove() }

    let first = try await project.describe()
    let second = try await project.describe()

    #expect(first == second)
    #expect(first.targets.map(\.name).sorted() == ["GameEngine", "GameEngineTests"])
    #expect(project.runner.invocations.count == 1)
  }

  @Test(
    "editing Package.swift or Package.resolved describes again — catches a module graph gone stale after a manifest change"
  )
  func manifestChangeInvalidates() async throws {
    let project = try Project()
    defer { project.remove() }

    _ = try await project.describe()
    try project.write("Package.swift", "// swift-tools-version: 6.2\n// edited\n")
    _ = try await project.describe()
    try project.write("Package.resolved", "{}\n")
    _ = try await project.describe()
    _ = try await project.describe()

    #expect(project.runner.invocations.count == 3)
  }

  @Test(
    "a failed describe is not cached — catches one transient SwiftPM failure blocking every later gate"
  )
  func failureNotCached() async throws {
    let project = try Project()
    defer { project.remove() }
    project.failNext.value.withLock { $0 = true }

    await #expect(throws: SwiftPMError.self) { _ = try await project.describe() }
    _ = try await project.describe()
    _ = try await project.describe()

    #expect(project.runner.invocations.count == 2)
  }

  @Test(
    "dump-package answers are cached separately from describe — catches settings served from the describe entry"
  )
  func settingsCachedSeparately() async throws {
    let project = try Project()
    defer { project.remove() }
    let swiftPM = LiveSwiftPM(
      runner: project.runner, repositoryRoot: project.root.path,
      manifestCache: project.root.appending(path: ".harness/cache/manifests"))

    _ = try await swiftPM.describe(packageDirectory: Self.package)
    let settings = try await swiftPM.settings(packageDirectory: Self.package)
    _ = try await swiftPM.settings(packageDirectory: Self.package)

    #expect(settings.defaultIsolation["FeedCore"] == "MainActor")
    #expect(project.runner.invocations.map(\.arguments.last) == ["json", "dump-package"])
  }
}

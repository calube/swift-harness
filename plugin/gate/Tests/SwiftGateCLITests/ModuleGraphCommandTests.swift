import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

@Suite("module-graph command")
struct ModuleGraphCommandTests {
  /// Two real packages, one depending on the other's product through a local path, so the golden
  /// covers both an in-package edge and a cross-package one.
  static let fixture = Fixture.gateDirectory.appending(
    path: "Fixtures/module-graph/repo", directoryHint: .isDirectory)

  static let golden = """
    Modules by package (role, kind):
    - Logging: LogClient (client, client)
    - Orders: OrderQueueClient (client, client), OrderQueueClientLive (client-live, client), \
    OrderQueueCore (core, feature), OrderQueueUI (ui, feature)
    OrderQueueClientLive -> LogClient
    OrderQueueClientLive -> OrderQueueClient
    OrderQueueCore -> OrderQueueClient
    OrderQueueCoreTests -> OrderQueueCore
    OrderQueueUI -> OrderQueueCore
    """

  /// A copy, so `swift package describe` and the manifest cache write nothing into the checkout.
  private static func copyOfFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-module-graph-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    try FileManager.default.copyItem(at: fixture, to: root)
    return root
  }

  @Test(
    "a real two-package repository dumps its module map and dependency edges byte for byte — catches the design and plan skills handing agents a graph built some other way"
  )
  func golden() async throws {
    let root = try Self.copyOfFixture()
    defer { try? FileManager.default.removeItem(at: root) }

    let outcome = await ModuleGraphRun.run(
      root: root, swiftPM: ScopeResolution.liveSwiftPM(root: root))

    #expect(outcome == .dumped(Self.golden))
  }

  @Test(
    "a repository with no .swiftgate.toml fails naming the config — catches an empty dump passing as a graph with no modules"
  )
  func noConfig() async throws {
    let root = try Self.copyOfFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.removeItem(at: root.appending(path: ConfigLoader.fileName))

    let outcome = await ModuleGraphRun.run(
      root: root, swiftPM: FakeSwiftPM(serving: []))

    guard case .failed(let message) = outcome else {
      Issue.record("expected .failed, got \(outcome)")
      return
    }
    #expect(message.contains(ConfigLoader.fileName))
  }

  @Test(
    "a package SwiftPM can't describe fails naming it — catches a partial graph dumped as if complete"
  )
  func describeFailure() async throws {
    let root = try Self.copyOfFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let failing = FakeSwiftPM { _ throws(SwiftPMError) in
      throw .unparseableOutput(command: "package describe", detail: "boom")
    }

    let outcome = await ModuleGraphRun.run(root: root, swiftPM: failing)

    guard case .failed(let message) = outcome else {
      Issue.record("expected .failed, got \(outcome)")
      return
    }
    #expect(message.contains("Packages/Logging") || message.contains("Packages/Orders"))
  }
}

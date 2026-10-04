import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// Runs the built `swiftgate module-graph` on a copy of a real two-package repository, one package
/// depending on the other's product through a local path, so the golden holds both an in-package
/// edge and a cross-package one.
@Suite("module-graph command")
struct ModuleGraphCommandTests {
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

  struct Result {
    let status: SwiftGateAdapters.ExitStatus
    let stdout: String
    let stderr: String
  }

  /// A copy, so `swift package describe`, the manifest cache and coverage output write nothing
  /// into the checkout.
  private static func copyOfFixture() throws -> URL {
    let root = TestTemporaryDirectory.root
      .appending(path: "swiftgate-module-graph-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    try FileManager.default.copyItem(at: fixture, to: root)
    return root
  }

  /// Parses and runs `module-graph` in process on `root`, writing its dump to `output`. Returns
  /// the exit code.
  private static func moduleGraph(root: URL, output: URL) async throws -> Int32 {
    let parsed = try await SwiftGate.asyncParseAsRoot([
      "module-graph", "--repo", root.path, "--output", output.path,
    ])
    var command = try #require(parsed as? any AsyncParsableCommand)
    do {
      try await command.run()
      return 0
    } catch let exit as ExitCode {
      return exit.rawValue
    }
  }

  /// Runs the built binary in `root`, as a skill does from the repository toplevel, with the dump
  /// on stdout and the failure message on stderr.
  private static func moduleGraph(in root: URL) async throws -> Result {
    let binary = Fixture.gateDirectory.appending(path: ".build/debug/swiftgate").path
    let output = try await LiveProcessRunner().run(
      ProcessInvocation(
        executable: binary, arguments: ["module-graph"],
        environmentOverlay: [
          "LLVM_PROFILE_FILE": root.appending(path: "swiftgate-%p.profraw").path
        ],
        workingDirectory: root.path, timeout: .seconds(120)))
    return Result(status: output.status, stdout: output.stdout.text, stderr: output.stderr.text)
  }

  @Test(
    "a real two-package repository dumps its module map and dependency edges byte for byte — catches the design and plan skills handing agents a graph built some other way"
  )
  func golden() async throws {
    let root = try Self.copyOfFixture()
    defer { try? FileManager.default.removeItem(at: root) }

    let dump = root.appending(path: ".harness/plan-draft/x/module-graph.txt")

    #expect(try await Self.moduleGraph(root: root, output: dump) == 0)
    #expect(try String(contentsOf: dump, encoding: .utf8) == Self.golden)
    let result = try await Self.moduleGraph(in: root)
    #expect(result.status == .exited(0), "\(result.stderr)")
    #expect(result.stdout == Self.golden)
  }

  @Test(
    "the dump's module lines are the ones SessionStart shows for the same repository — catches a pack's graph disagreeing with the session's map"
  )
  func sameMapAsSessionStart() async throws {
    let root = try Self.copyOfFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    guard case .success(let config?) = StaticCheckInputs.loadConfig(root: root) else {
      Issue.record("the fixture's .swiftgate.toml doesn't load")
      return
    }
    let entries: [SessionContext.ModuleEntry]
    switch await SessionStartHook.moduleMap(
      root: root, config: config, swiftPM: ScopeResolution.liveSwiftPM(root: root))
    {
    case .success(let built): entries = built
    case .failure(let reason):
      Issue.record("SessionStart built no module map for the fixture: \(reason.text)")
      return
    }
    let session = SessionContext.render(
      SessionContext.Inputs(
        projectName: "fixture", modules: entries, xcode: nil, plans: .none, notes: []))

    let dump = root.appending(path: "module-graph.txt")
    #expect(try await Self.moduleGraph(root: root, output: dump) == 0)

    let text = try String(contentsOf: dump, encoding: .utf8)
    let mapLines = text.split(separator: "\n").filter { !$0.contains(" -> ") }
    #expect(mapLines.count == 3, "\(text)")
    for line in mapLines {
      #expect(session.contains(line), "\(line)")
    }
  }

  @Test(
    "a repository with no .swiftgate.toml exits 2 naming the config and prints no dump — catches an empty dump passing as a graph with no modules"
  )
  func noConfig() async throws {
    let root = try Self.copyOfFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.removeItem(at: root.appending(path: ".swiftgate.toml"))
    let dump = root.appending(path: "module-graph.txt")

    #expect(try await Self.moduleGraph(root: root, output: dump) == 2)
    #expect(!FileManager.default.fileExists(atPath: dump.path))
    let result = try await Self.moduleGraph(in: root)

    #expect(result.status == .exited(2))
    #expect(result.stdout.isEmpty)
    #expect(result.stderr.contains(".swiftgate.toml"), "\(result.stderr)")
  }

  @Test(
    "a package SwiftPM can't describe exits 2 naming it and prints no dump — catches a partial graph dumped as if complete"
  )
  func describeFailure() async throws {
    let root = try Self.copyOfFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("this is not a manifest\n".utf8).write(
      to: root.appending(path: "Packages/Logging/Package.swift"))
    let dump = root.appending(path: "module-graph.txt")

    #expect(try await Self.moduleGraph(root: root, output: dump) == 2)
    #expect(!FileManager.default.fileExists(atPath: dump.path))
    let result = try await Self.moduleGraph(in: root)

    #expect(result.status == .exited(2))
    #expect(result.stdout.isEmpty)
    #expect(result.stderr.contains("Packages/Logging"), "\(result.stderr)")
  }
}

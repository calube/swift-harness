import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// Runs the built `swiftgate` as `bin/swiftgate` would, with the shim's variables set or not, and
/// reads the hook event it writes.
@Suite("the built swiftgate names its binary in its events")
struct GateBinaryEventsTests {
  static let hash = "b49790db12112294"
  static let config = """
    schema = 1
    xcode = "26.2"
    app_scheme = "App"
    packages = ["Packages/*"]

    [simulator]
    device = "iPhone 17"
    os = "26.2"

    """

  struct Project {
    let root: URL
    var project: URL { root.appending(path: "project", directoryHint: .isDirectory) }
    var plugin: URL { root.appending(path: "plugin", directoryHint: .isDirectory) }

    init() throws {
      root = TestTemporaryDirectory.root
        .appending(path: "swiftgate-binary-\(UUID().uuidString)", directoryHint: .isDirectory)
        .resolvingSymlinksInPath()
      try FileManager.default.createDirectory(
        at: project.appending(path: ".git", directoryHint: .isDirectory),
        withIntermediateDirectories: true)
      try Data(GateBinaryEventsTests.config.utf8).write(
        to: project.appending(path: ConfigLoader.fileName))
      let manifest = plugin.appending(path: GateBinaryReader.manifestPath)
      try FileManager.default.createDirectory(
        at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(#"{"name":"swift-harness","version":"0.4.1"}"#.utf8).write(to: manifest)
    }

    /// Runs `hook pre-tool-use` on an allowed Bash call with `shim` added to the environment.
    func hook(shim: [String: String]) async throws -> (
      status: SwiftGateAdapters.ExitStatus, stderr: String
    ) {
      var environment = ProcessInfo.processInfo.environment
      environment[GateBinary.sourceHashVariable] = nil
      environment[GateBinaryReader.harnessRootVariable] = nil
      environment["LLVM_PROFILE_FILE"] = root.appending(path: "%p.profraw").path
      environment.merge(shim) { _, new in new }
      let output = try await LiveProcessRunner(baseEnvironment: environment).run(
        ProcessInvocation(
          executable: Fixture.gateDirectory.appending(path: ".build/debug/swiftgate").path,
          arguments: ["hook", "pre-tool-use"], workingDirectory: project.path,
          standardInput: Data(
            #"{"session_id":"s-1","cwd":"\#(project.path)","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}"#
              .utf8),
          timeout: .seconds(120)))
      return (output.status, output.stderr.text)
    }

    var hookStream: String {
      String(
        decoding: FileManager.default.contents(
          atPath: StateRoot.tree(project).url(RunLayout.eventsFile(.hook)).path) ?? Data(),
        as: UTF8.self)
    }
  }

  @Test(
    "a hook run with the shim's hash and plugin root writes an event naming that hash and the plugin's version — catches an event written without the binary hash when the shim set it"
  )
  func shimHashReachesTheEvent() async throws {
    let project = try Project()
    defer { try? FileManager.default.removeItem(at: project.root) }

    let result = try await project.hook(shim: [
      GateBinary.sourceHashVariable: Self.hash,
      GateBinaryReader.harnessRootVariable: project.plugin.path,
    ])

    #expect(result.status == .exited(0), "\(result.stderr)")
    let events = try HarnessEventJSON.decode(Data(project.hookStream.utf8)).events
    #expect(events.count == 1)
    #expect(
      events.first?.source.binary
        == (try GateBinary(sourceHash: Self.hash, pluginVersion: "0.4.1")))
    #expect(!project.hookStream.contains(project.plugin.path))
  }

  @Test(
    "a hash variable holding an absolute path writes the event with no binary and never the path — catches an absolute path in the binary field"
  )
  func pathValuedHashIsLeftOut() async throws {
    let project = try Project()
    defer { try? FileManager.default.removeItem(at: project.root) }
    let path = project.root.appending(path: "cache/bin/\(Self.hash)/swiftgate").path

    let result = try await project.hook(shim: [GateBinary.sourceHashVariable: path])

    #expect(result.status == .exited(0), "\(result.stderr)")
    let events = try HarnessEventJSON.decode(Data(project.hookStream.utf8)).events
    #expect(events.count == 1)
    #expect(events.first?.source.binary == nil)
    #expect(!project.hookStream.contains(path))
    #expect(result.stderr.contains(GateBinary.sourceHashVariable), "\(result.stderr)")
  }
}

import Foundation
import SwiftGateAdapters
import SwiftGateTestSupport
import Testing

/// The harness's non-Swift tests (`tests/`), run here so `swift test` is the one contributor gate.
/// Each is skipped, visibly, only when its interpreter is missing from `PATH`.
@Suite("repository scripts")
struct RepositoryScriptTests {
  static func onPath(_ name: String) -> Bool {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    return path.split(separator: ":").contains {
      FileManager.default.isExecutableFile(atPath: "\($0)/\(name)")
    }
  }

  /// Every `tests/*_test.mjs` name in `directory`, sorted for a deterministic run order. A missing
  /// or unreadable directory reports no scripts rather than throwing, so a fresh checkout without
  /// `tests/` still discovers zero cleanly.
  static func mjsScripts(in directory: URL) -> [String] {
    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    else { return [] }
    return entries.map(\.lastPathComponent).filter { $0.hasSuffix("_test.mjs") }.sorted()
  }

  /// Discovered once per test-run so a workflow task's new `tests/*_test.mjs` is picked up without
  /// editing this file (spec Decisions table).
  static let discoveredMjsScripts = mjsScripts(
    in: Fixture.harnessCheckout.appending(path: "tests", directoryHint: .isDirectory))

  func run(_ executable: String, _ script: String, timeout: Duration) async throws -> ProcessOutput
  {
    try await LiveProcessRunner().run(
      ProcessInvocation(
        executable: executable,
        arguments: [Fixture.harnessCheckout.appending(path: script).path],
        workingDirectory: Fixture.harnessCheckout.path, timeout: timeout))
  }

  @Test(
    "tests/*_test.mjs discovery finds every matching script and ignores everything else — catches a new workflow script never registered for the repository-script gate"
  )
  func discoversMjsScripts() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "repository-script-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    for name in ["alpha_test.mjs", "beta_test.mjs", "helper.mjs", "shim_test.sh", "README.md"] {
      #expect(
        FileManager.default.createFile(
          atPath: directory.appending(path: name).path, contents: Data()))
    }
    #expect(Self.mjsScripts(in: directory) == ["alpha_test.mjs", "beta_test.mjs"])
  }

  @Test(
    "every tests/*_test.mjs script passes with no check silently skipped — catches a workflow regression shipping outside swift test, or a check that passes unrun",
    .enabled(if: onPath("node"), "node is not on PATH"),
    arguments: discoveredMjsScripts)
  func workflowScript(_ name: String) async throws {
    let output = try await run("node", "tests/\(name)", timeout: .seconds(60))
    #expect(output.status.isSuccess, "\(output.stdout.text)\n\(output.stderr.text)")
    #expect(output.stdout.text.contains("ok   "), "no test reported")
    let skipped = output.stdout.text.split(separator: "\n", omittingEmptySubsequences: false)
      .first { $0.lowercased().hasPrefix("skip") }
    #expect(
      skipped == nil,
      "a check passed without running instead of failing: \(skipped.map(String.init) ?? "")")
  }

  @Test(
    "swiftgate shim caches and rebuilds — catches a stale binary running old rules or a cold hook blocking",
    .enabled(if: onPath("bash") && onPath("swift"), "bash or swift is not on PATH"))
  func shim() async throws {
    let output = try await run("bash", "tests/shim_test.sh", timeout: .seconds(600))
    #expect(output.status.isSuccess, "\(output.stdout.text)\n\(output.stderr.text)")
    #expect(output.stdout.text.contains("shim_test: PASS"))
  }
}

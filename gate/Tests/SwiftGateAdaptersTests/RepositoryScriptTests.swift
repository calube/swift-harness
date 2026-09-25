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

  func run(_ executable: String, _ script: String, timeout: Duration) async throws -> ProcessOutput
  {
    try await LiveProcessRunner().run(
      ProcessInvocation(
        executable: executable,
        arguments: [Fixture.checkoutRoot.appending(path: script).path],
        workingDirectory: Fixture.checkoutRoot.path, timeout: timeout))
  }

  @Test(
    "review workflow script tests pass — catches review.js regressions shipping outside swift test",
    .enabled(if: onPath("node"), "node is not on PATH"))
  func reviewWorkflow() async throws {
    let output = try await run("node", "tests/review_workflow_test.mjs", timeout: .seconds(60))
    #expect(output.status.isSuccess, "\(output.stdout.text)\n\(output.stderr.text)")
    #expect(output.stdout.text.contains("ok   "), "no test reported")
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

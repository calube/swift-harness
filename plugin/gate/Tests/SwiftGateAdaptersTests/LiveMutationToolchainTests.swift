import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// `swift build`/`swift test` replayed from the recorded probe runs (`SwiftTest/*`).
@Suite("LiveMutationToolchain")
struct LiveMutationToolchainTests {
  private static let root = URL(filePath: "/scratch/tree", directoryHint: .isDirectory)
  private static let selection = HostTestSelection(
    packagePath: "Packages/Probe",
    targets: [TestTargetReference(name: "ProbeTests", path: "Packages/Probe/Tests/ProbeTests")])

  private static func reportPath() -> String {
    TestTemporaryDirectory.root
      .appending(path: "swiftgate-mutate-\(UUID().uuidString)/1-probe.xml").path
  }

  /// Answers `swift test` like the recorded `scenario`, writing its reports where asked.
  private static func replaying(_ scenario: String) -> FakeProcessRunner {
    FakeProcessRunner { invocation in
      if let index = invocation.arguments.firstIndex(of: "--xunit-output") {
        let path = invocation.arguments[index + 1]
        for (fixture, destination) in [
          ("\(scenario).xml", path),
          ("\(scenario)-swift-testing.xml", LiveSwiftPM.swiftTestingReportPath(for: path)),
        ] {
          if let data = try? Fixture.data("SwiftTest/\(fixture)") {
            FileManager.default.createFile(atPath: destination, contents: data)
          }
        }
      }
      let status =
        Int32(
          ((try? Fixture.text("SwiftTest/\(scenario).status")) ?? "1")
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
      return ProcessOutput(
        status: .exited(status), stdout: (try? Fixture.text("SwiftTest/\(scenario).stdout")) ?? "",
        stderr: (try? Fixture.text("SwiftTest/\(scenario).stderr")) ?? "", elapsed: .seconds(2))
    }
  }

  @Test(
    "tests run with --skip-build in the scratch package under the mutant timeout and count executed cases from both reports — catches rebuilding outside the timeout or reading the wrong tree"
  )
  func passing() async throws {
    let runner = Self.replaying("pass")
    let (result, elapsed) = await LiveMutationToolchain(runner: runner).test(
      root: Self.root, selection: Self.selection, timeout: .seconds(25),
      reportPath: Self.reportPath())

    let expected = try ["pass.xml", "pass-swift-testing.xml"].flatMap {
      try XUnitReport.parse(Fixture.data("SwiftTest/\($0)"))
    }.count { $0.isExecuted }
    #expect(result == .passed(executed: expected))
    #expect(elapsed == .seconds(2))
    let invocation = try #require(runner.invocations.first)
    #expect(Array(invocation.arguments.prefix(3)) == ["test", "--skip-build", "--parallel"])
    #expect(invocation.arguments.suffix(2) == ["--filter", Self.selection.filter])
    #expect(invocation.workingDirectory == "/scratch/tree/Packages/Probe")
    #expect(invocation.timeout == .seconds(25))
    #expect(invocation.environmentOverlay["SNAPSHOT_TESTING_RECORD"] == "never")
  }

  @Test(
    "a failing run names the failing tests from both frameworks' reports — catches a kill reported without the test that made it"
  )
  func failing() async throws {
    let (result, _) = await LiveMutationToolchain(runner: Self.replaying("fail")).test(
      root: Self.root, selection: Self.selection, timeout: .seconds(25),
      reportPath: Self.reportPath())

    #expect(
      result
        == .failed(failingTests: [
          "ProbeTests.FailXCTests/testDoublesWrong", "ProbeTests.FailSwiftTests/doublesWrong()",
        ]))
  }

  @Test(
    "a test process stopped by the timeout is timedOut, not an environment failure — catches an infinite-loop mutant reported BLOCKED"
  )
  func timeout() async throws {
    let runner = FakeProcessRunner { invocation throws(ProcessRunnerError) in
      throw .timedOut(
        executable: invocation.executable, after: .seconds(25), stdout: CapturedStream(),
        stderr: CapturedStream())
    }
    let (result, _) = await LiveMutationToolchain(runner: runner).test(
      root: Self.root, selection: Self.selection, timeout: .seconds(25),
      reportPath: Self.reportPath())
    #expect(result == .timedOut(after: .seconds(25)))
  }

  @Test(
    "a build the compiler rejects is failed with its error lines, a build that cannot launch is unavailable, and a build asks for no debug information — catches an unviable mutant counted as an environment failure, or dsymutil run over every mutant's test bundle"
  )
  func build() async throws {
    let stderr = try Fixture.text("SwiftTest/build-error.stderr")
    let stdout = try Fixture.text("SwiftTest/build-error.stdout")
    let rejecting = FakeProcessRunner { _ in
      ProcessOutput(status: .exited(1), stdout: stdout, stderr: stderr)
    }
    let result = await LiveMutationToolchain(runner: rejecting).buildTests(
      root: Self.root, packageDirectory: "Packages/Probe")
    guard case .failed(let log) = result else {
      Issue.record("expected failed, got \(result)")
      return
    }
    #expect(log.contains("error:"))
    let invocation = try #require(rejecting.invocations.first)
    #expect(
      invocation.arguments == [
        "build", "--build-tests", "--only-use-versions-from-resolved-file", "-debug-info-format",
        "none",
      ])
    #expect(invocation.workingDirectory == "/scratch/tree/Packages/Probe")

    let missing = FakeProcessRunner { invocation throws(ProcessRunnerError) in
      throw .launchFailed(executable: invocation.executable, reason: "no such file")
    }
    let unavailable = await LiveMutationToolchain(runner: missing).buildTests(
      root: Self.root, packageDirectory: "")
    guard case .unavailable = unavailable else {
      Issue.record("expected unavailable, got \(unavailable)")
      return
    }
  }
}

import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("XcresultReader")
struct XcresultReaderTests {
  /// Answers each `xcresulttool` call with the recorded output of `scenario`.
  private func replaying(_ scenario: String) -> FakeProcessRunner {
    FakeProcessRunner { invocation throws(ProcessRunnerError) in
      let part = invocation.arguments.contains("build-results") ? "build-results" : "tests"
      if let json = try? Fixture.data("Xcresult/\(scenario).\(part).json") {
        return ProcessOutput(
          status: .exited(0), stdout: CapturedStream(bytes: json), stderr: CapturedStream(),
          elapsed: .zero)
      }
      let stderr = (try? Fixture.text("Xcresult/\(scenario).\(part).stderr")) ?? ""
      let status =
        (try? Fixture.text("Xcresult/\(scenario).\(part).status"))
        .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 1
      return ProcessOutput(status: .exited(status), stderr: stderr)
    }
  }

  @Test(
    "reads the test tree and build results with the Xcode 26.2 subcommands — catches the reader calling a subcommand 26.2 does not have"
  )
  func invocations() async throws {
    let runner = replaying("fail")

    let contents = try await LiveXcresultReader(runner: runner).read(bundlePath: "/r/T2.xcresult")

    #expect(
      runner.invocations.map { [$0.executable] + $0.arguments } == [
        [
          "/usr/bin/xcrun", "xcresulttool", "get", "test-results", "tests", "--path",
          "/r/T2.xcresult",
        ],
        ["/usr/bin/xcrun", "xcresulttool", "get", "build-results", "--path", "/r/T2.xcresult"],
      ])
    #expect(contents.testResults == (try Fixture.data("Xcresult/fail.tests.json")))
    #expect(contents.buildResults == (try Fixture.data("Xcresult/fail.build-results.json")))
  }

  @Test(
    "a bundle xcodebuild never wrote is a BLOCKED read error naming the path — catches a missing bundle surfacing as an empty GREEN run"
  )
  func missingBundle() async throws {
    let error = await #expect(throws: XcresultReadError.self) {
      try await LiveXcresultReader(runner: replaying("missing-bundle"))
        .read(bundlePath: "/SCRATCH/missing.xcresult")
    }

    #expect(error?.verdict == .blocked)
    #expect(
      error?.message.contains("File or directory doesn't exist at path: /SCRATCH/missing.xcresult")
        == true)
  }

  @Test(
    "the recorded skip run read end to end is RED only for reasonless skips — catches the reader dropping the messages that carry skip reasons"
  )
  func skipEndToEnd() async throws {
    let contents = try await LiveXcresultReader(runner: replaying("skip"))
      .read(bundlePath: "/r/T2.xcresult")
    let target = TestTargetReference(
      name: "CounterUISnapshotTests", path: "Packages/CounterFeature/Tests/CounterUISnapshotTests")

    let outcome = SimulatorTestEvidenceRules.evaluate(
      SimulatorTestEvidence(
        tier: .t2, testTargets: [target], succeeded: true, testResults: contents.testResults,
        buildResults: contents.buildResults, testSourceFiles: [], repositoryRoot: "/REPO"))

    #expect(
      outcome.findings.filter { $0.ruleID == "t2.skip-without-reason" }.count == 2)
    #expect(outcome.counts.skipped == 4)
  }
}

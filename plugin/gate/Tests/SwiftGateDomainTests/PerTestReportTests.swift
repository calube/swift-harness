import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// A captured `F/AreaRuns/<runner>/<case>/` run, read the way the live runner reads it: stdout
/// with stderr folded in, and every report the run wrote, combined.
private func capturedRun(_ runner: String, _ caseName: String) throws -> AreaCommandOutcome {
  let directory = Fixture.directory.appending(
    path: "AreaRuns/\(runner)/\(caseName)", directoryHint: .isDirectory)
  let read = { (name: String) in
    try String(contentsOf: directory.appending(path: name), encoding: .utf8)
  }
  let exit = try #require(Int32(try read("exit").trimmingCharacters(in: .whitespacesAndNewlines)))
  let output = try read("stdout") + read("stderr")
  var documents: [Data] = []
  for name in ["junit.xml", "junit-swift-testing.xml"] {
    if let data = FileManager.default.contents(atPath: directory.appending(path: name).path) {
      documents.append(data)
    }
  }
  let reports = directory.appending(path: "junit", directoryHint: .isDirectory)
  if let names = try? FileManager.default.contentsOfDirectory(atPath: reports.path) {
    for name in names.sorted() where name.hasSuffix(".xml") {
      documents.append(try Data(contentsOf: reports.appending(path: name)))
    }
  }
  return AreaOutcomeReading.outcome(
    end: .exited(exit), output: output, junit: JUnitReports.combined(documents))
}

/// 1 runner's captures: a base run where `flaky` fails, and a head run where `fresh` fails too.
struct CapturedRunner: Sendable, CustomTestStringConvertible {
  let directory: String
  let flaky: String
  let fresh: String

  var testDescription: String { directory }
}

private let runners = [
  CapturedRunner(
    directory: "python", flaky: "tests.test_alpha.test_flaky", fresh: "tests.test_beta.test_new"),
  CapturedRunner(
    directory: "vitest", flaky: "test/alpha.test.js.alpha > flaky", fresh: "test/beta.test.js.new"),
  // jest-junit names a case `<describe> <test>` in both attributes, with a leading space at the
  // top level.
  CapturedRunner(directory: "jest", flaky: "alpha flaky", fresh: " new"),
  CapturedRunner(
    directory: "gradle", flaky: "example.alpha.AlphaTest.flaky()",
    fresh: "example.beta.BetaTest.fresh()"),
  CapturedRunner(
    directory: "maven", flaky: "example.AlphaTest.flaky", fresh: "example.BetaTest.fresh"),
  CapturedRunner(
    directory: "ruby", flaky: "spec.alpha_spec.alpha flaky", fresh: "spec.beta_spec.beta new"),
  // Swift Testing's cases are only in the second report `--xunit-output` writes.
  CapturedRunner(
    directory: "swift", flaky: "SwiftBaseTests.AlphaTests.testFlaky",
    fresh: "SwiftBaseTests.fresh()"),
  // 2 targets each hold a `tests::flaky`; only the target tells them apart.
  CapturedRunner(
    directory: "cargo", flaky: "unittests src/lib.rs (cargobase).tests::flaky",
    fresh: "tests/beta.rs (beta).tests::flaky"),
]

private func key(_ runner: CapturedRunner) -> BaselineStepKey {
  BaselineStepKey(area: runner.directory, step: .test, command: "test")
}

@Suite("test failures read per test, for every runner discover asks for a report")
struct PerTestReportTests {
  @Test(
    "a new failing test is not absorbed by a base that failed a different one — catches a runner whose failures baseline as the whole step",
    arguments: runners)
  func newFailureStillGates(runner: CapturedRunner) throws {
    let base = BaselineStepResult.of(try capturedRun(runner.directory, "baseline-base"))
    let head = BaselineStepResult.of(try capturedRun(runner.directory, "baseline-head"))

    let verdict = Baseline.compare(head: [key(runner): head], base: [key(runner): base])

    #expect(verdict.remaining == [BaselineFailure(key: key(runner), test: runner.fresh)])
    #expect(verdict.absorbed == [BaselineFailure(key: key(runner), test: runner.flaky)])
  }

  @Test(
    "a captured report reads as exactly its failing tests — catches passing cases, a missed second report or a wrong attribute read as an id",
    arguments: runners)
  func reportReadsExactly(runner: CapturedRunner) throws {
    #expect(
      BaselineStepResult.of(try capturedRun(runner.directory, "baseline-base"))
        == .failedTests([runner.flaky]))
    #expect(
      BaselineStepResult.of(try capturedRun(runner.directory, "baseline-head"))
        == .failedTests([runner.flaky, runner.fresh]))
  }

  @Test(
    "a build or load failure no test result holds fails the whole step, which a base of named tests can't absorb — catches a compile error hidden behind its neighbours' test ids",
    arguments: ["python", "gradle", "maven", "ruby", "swift", "cargo"])
  func buildFailureFailsWholeStep(directory: String) throws {
    let runner = try #require(runners.first { $0.directory == directory })
    let head = BaselineStepResult.of(try capturedRun(directory, "build-fail"))
    let base = BaselineStepResult.of(try capturedRun(directory, "baseline-base"))

    #expect(head == .failed)
    let verdict = Baseline.compare(head: [key(runner): head], base: [key(runner): base])
    #expect(verdict.remaining == [BaselineFailure(key: key(runner), test: nil)])
    #expect(verdict.absorbed.isEmpty)
  }

  @Test(
    "a failure the runner reports outside its JUnit report fails the whole step — catches a Maven module that didn't compile, or an RSpec suite hook that raised, dropped because the rest reads per test",
    arguments: [("maven", "multi-module-build-fail"), ("ruby", "suite-hook-fail")])
  func failureOutsideReport(directory: String, caseName: String) throws {
    let outcome = try capturedRun(directory, caseName)
    guard case .failed(_, _, let junit) = outcome else {
      Issue.record("the captured run read as \(outcome)")
      return
    }
    #expect(junit == nil)
    #expect(BaselineStepResult.of(outcome) == .failed)
  }

  @Test(
    "a suite that fails to load names itself, so the base's failing test can't absorb it — catches a jest or vitest suite error left out of the report",
    arguments: [
      ("vitest", "test/broken.test.js"),
      ("jest", "Test suite failed to run.test/broken.test.js"),
    ])
  func suiteLoadFailureGates(directory: String, suite: String) throws {
    let runner = try #require(runners.first { $0.directory == directory })
    let head = BaselineStepResult.of(try capturedRun(directory, "build-fail"))
    let base = BaselineStepResult.of(try capturedRun(directory, "baseline-base"))

    let verdict = Baseline.compare(head: [key(runner): head], base: [key(runner): base])

    #expect(verdict.remaining.map(\.test).contains(suite))
    #expect(verdict.absorbed == [BaselineFailure(key: key(runner), test: runner.flaky)])
  }

  @Test(
    "an error vitest catches after a test ended gates on its own — catches an unhandled error absorbed with the base's failing test"
  )
  func vitestUnhandledErrorGates() throws {
    #expect(
      BaselineStepResult.of(try capturedRun("vitest", "unhandled"))
        == .failedTests([
          "test/alpha.test.js.alpha > flaky",
          "vitest unhandled errors.Uncaught Exception: thrown after the test ended",
        ]))
  }

  @Test(
    "pnpm hands the report flags to the script as npm does after its separator — catches a pnpm area whose report is never written",
    arguments: ["vitest", "jest"])
  func pnpmRunsWriteReports(directory: String) throws {
    let runner = try #require(runners.first { $0.directory == directory })
    #expect(
      BaselineStepResult.of(try capturedRun(directory, "pnpm-head"))
        == .failedTests([runner.flaky, runner.fresh]))
  }

  @Test(
    "a truncated report fails the whole step, and so does a cargo run whose result line counts a failure no line names — catches a half-read report taken as its readable cases"
  )
  func misreadReportsFailWhole() throws {
    let report = try #require(
      FileManager.default.contents(
        atPath: Fixture.directory.appending(path: "AreaRuns/python/baseline-head/junit.xml").path))
    let truncated = AreaOutcomeReading.outcome(
      end: .exited(1), output: "", junit: report.prefix(report.count * 2 / 3))
    #expect(BaselineStepResult.of(truncated) == .failed)

    let output = try String(
      contentsOf: Fixture.directory.appending(path: "AreaRuns/cargo/baseline-head/stdout"),
      encoding: .utf8)
    #expect(CargoTestReport.junit(fromOutput: output) != nil)
    let unnamed = output.replacingOccurrences(of: "test tests::flaky ... FAILED\n", with: "")
    #expect(CargoTestReport.junit(fromOutput: unnamed) == nil)
  }

  @Test(
    "Swift Testing's report sits beside the one --xunit-output names — catches the second report left unread"
  )
  func swiftTestingCompanion() {
    #expect(
      JUnitReports.companionPaths(of: "/git/junit/core.test.xml")
        == ["/git/junit/core.test-swift-testing.xml"])
  }
}

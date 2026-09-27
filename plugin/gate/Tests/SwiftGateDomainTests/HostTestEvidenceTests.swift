import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("T1 evidence rules")
struct HostTestEvidenceTests {
  private static let package = "gate/Fixtures/swifttest/XUnitProbe"
  private static let probeTests = TestTargetReference(
    name: "ProbeTests", path: "\(package)/Tests/ProbeTests")
  private static let emptyTests = TestTargetReference(
    name: "EmptyTests", path: "\(package)/Tests/EmptyTests")
  private static let sources = ["Crash", "Fail", "Pass", "SharedFirstLine", "Skip"].map {
    "\(package)/Tests/ProbeTests/\($0)Tests.swift"
  }

  /// A recorded `swift test` run of the probe package; `succeeded` overrides the recorded status.
  private func evidence(
    _ scenario: String, targets: [TestTargetReference] = [Self.probeTests], succeeded: Bool? = nil
  ) throws -> HostTestEvidence {
    let directory = Fixture.directory.appending(path: "SwiftTest")
    func optional(_ name: String) -> Data? {
      try? Data(contentsOf: directory.appending(path: name))
    }
    let status = try Fixture.text("SwiftTest/\(scenario).status")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return HostTestEvidence(
      packagePath: Self.package, testTargets: targets,
      succeeded: succeeded ?? (status == "0"),
      xctestReport: optional("\(scenario).xml"),
      swiftTestingReport: optional("\(scenario)-swift-testing.xml"),
      stdout: try Fixture.text("SwiftTest/\(scenario).stdout"),
      stderr: try Fixture.text("SwiftTest/\(scenario).stderr"),
      testSourceFiles: Self.sources, repositoryRoot: Fixture.repositoryRoot)
  }

  @Test(
    "passing XCTest and Swift Testing cases are GREEN with both counted — catches one framework's report being ignored"
  )
  func pass() throws {
    let outcome = HostTestEvidenceRules.evaluate(try evidence("pass"))

    #expect(outcome.verdict == .green)
    #expect(outcome.counts == (try TestCounts(passed: 2, failed: 0, skipped: 0)))
    #expect(outcome.findings.isEmpty)
  }

  @Test(
    "each failure is RED with its assertion text at the test's file:line — catches a failure reported without where or why"
  )
  func failures() throws {
    let outcome = HostTestEvidenceRules.evaluate(try evidence("fail"))

    #expect(outcome.verdict == .red)
    #expect(outcome.counts == (try TestCounts(passed: 0, failed: 2, skipped: 0)))
    let located = outcome.findings.map { "\($0.ruleID) \($0.file):\($0.line ?? 0)" }
    #expect(
      located == [
        "t1.test-failed \(Self.package)/Tests/ProbeTests/FailTests.swift:7",
        "t1.test-failed \(Self.package)/Tests/ProbeTests/FailTests.swift:13",
      ])
    try #require(outcome.findings.count == 2)
    #expect(
      outcome.findings[0].message.contains(#"XCTAssertEqual failed: ("4") is not equal to ("5")"#))
    #expect(outcome.findings[0].message.contains("FailXCTests.testDoublesWrong"))
    #expect(outcome.findings[1].message.contains("Expectation failed: (double(3) → 6) == 7"))
    #expect(outcome.findings[1].message.contains("FailSwiftTests.doublesWrong()"))
  }

  @Test(
    "failures whose console issues share a first line are each located at their own line — catches every TCA state-diff failure pointing at the first failing test's line"
  )
  func sharedFirstLine() throws {
    let outcome = HostTestEvidenceRules.evaluate(try evidence("shared-first-line"))

    let file = "\(Self.package)/Tests/ProbeTests/SharedFirstLineTests.swift"
    let located = outcome.findings.map { finding -> String in
      let test = finding.message.contains("firstMismatch()") ? "first" : "second"
      return "\(test) \(finding.file):\(finding.line ?? 0)"
    }
    #expect(located.sorted() == ["first \(file):6", "second \(file):10"])
  }

  @Test(
    "a skip without a reason is RED, a reasoned skip is counted — catches silently disabled tests")
  func skips() throws {
    let outcome = HostTestEvidenceRules.evaluate(try evidence("skip"))

    #expect(outcome.verdict == .red)
    #expect(outcome.counts.skipped == 2)
    #expect(outcome.findings.map(\.ruleID) == ["t1.skip-without-reason"])
    #expect(outcome.findings.first?.message.contains("disabledWithoutReason()") == true)
  }

  @Test(
    "a selected target that executes zero tests is RED — catches a green run that tested nothing")
  func zeroTests() throws {
    let outcome = HostTestEvidenceRules.evaluate(
      try evidence("zero", targets: [Self.emptyTests]))

    #expect(outcome.verdict == .red)
    #expect(outcome.findings.map(\.ruleID) == ["t1.no-tests"])
    #expect(outcome.findings.first?.file == Self.emptyTests.path)
  }

  @Test(
    "a crashing test is RED with the fatal error, even when a report is truncated — catches a crash read as an environment problem"
  )
  func crash() throws {
    let outcome = HostTestEvidenceRules.evaluate(try evidence("crash"))

    #expect(outcome.verdict == .red)
    #expect(outcome.findings.map(\.ruleID) == ["t1.test-failed", "t1.crashed"])
    #expect(outcome.findings.allSatisfy { $0.message.contains("Fatal error: Index out of range") })
    try #require(outcome.findings.count == 2)
    #expect(outcome.findings[1].message.contains("crashes()"))
  }

  @Test(
    "a compile error in the repository is RED at its file:line — catches a broken build reported as BLOCKED"
  )
  func buildError() throws {
    let outcome = HostTestEvidenceRules.evaluate(try evidence("build-error"))

    #expect(outcome.verdict == .red)
    #expect(outcome.findings.map(\.ruleID) == ["t1.build-failed"])
    #expect(outcome.findings.first?.file == "\(Self.package)/Sources/Probe/Probe.swift")
    #expect(outcome.findings.first?.line == 2)
    #expect(outcome.findings.first?.message.contains("cannot convert value") == true)
  }

  @Test(
    "a compile error inside a #expect macro expansion is RED at the test's file:line, never BLOCKED — catches a session ending on a test that doesn't compile"
  )
  func macroExpansionCompileError() throws {
    let outcome = HostTestEvidenceRules.evaluate(try evidence("macro-compile-error"))

    #expect(outcome.verdict == .red)
    #expect(outcome.findings.map(\.ruleID) == ["t1.build-failed"])
    #expect(outcome.findings.first?.file == "\(Self.package)/Tests/ProbeTests/PassTests.swift")
    #expect(outcome.findings.first?.line == 20)
    #expect(
      outcome.findings.first?.message.contains("errors thrown from here are not handled") == true)
  }

  @Test(
    "a build failure with no repository location is BLOCKED — catches toolchain breakage sent to the code"
  )
  func environmentFailure() throws {
    let outcome = HostTestEvidenceRules.evaluate(try evidence("stale-module-cache"))

    #expect(outcome.verdict == .blocked)
    #expect(outcome.findings.allSatisfy { !$0.severity.failsGate })
    #expect(outcome.findings.first?.message.contains("PCH was compiled") == true)
  }

  @Test(
    "a missing Package.resolved under --only-use-versions-from-resolved-file is RED naming the fix — catches a stale lockfile reported as a generic no-evidence BLOCKED"
  )
  func resolvedFileMissing() throws {
    let outcome = HostTestEvidenceRules.evaluate(try evidence("resolved-file-missing"))

    #expect(outcome.verdict == .red)
    #expect(outcome.findings.map(\.ruleID) == ["swiftgate.resolved-file-stale"])
    #expect(outcome.findings.first?.message.contains("a resolved file is required") == true)
    #expect(
      outcome.findings.first?.message.contains(
        "run `swift package resolve` in \(Self.package) and commit Package.resolved") == true)
  }

  @Test(
    "an out-of-date Package.resolved under --only-use-versions-from-resolved-file is RED naming the fix — catches the same stale-lockfile message going unrecognized"
  )
  func resolvedFileStale() throws {
    let outcome = HostTestEvidenceRules.evaluate(try evidence("resolved-file-stale"))

    #expect(outcome.verdict == .red)
    #expect(outcome.findings.map(\.ruleID) == ["swiftgate.resolved-file-stale"])
    #expect(
      outcome.findings.first?.message.contains("an out-of-date resolved file was detected")
        == true)
    #expect(
      outcome.findings.first?.message.contains(
        "run `swift package resolve` in \(Self.package) and commit Package.resolved") == true)
  }

  @Test(
    "a failing exit with all-passing reports is BLOCKED — catches exit codes and evidence disagreeing silently"
  )
  func unexplainedExit() throws {
    let outcome = HostTestEvidenceRules.evaluate(try evidence("pass", succeeded: false))

    #expect(outcome.verdict == .blocked)
    #expect(outcome.findings.map(\.ruleID) == ["t1.runner"])
  }

  @Test(
    "combining packages sums counts and merges verdicts into one T1 tier — catches one package's RED hidden by another's GREEN"
  )
  func combine() throws {
    let result = try HostTestEvidenceRules.tierResult(
      [
        HostTestEvidenceRules.evaluate(try evidence("pass")),
        HostTestEvidenceRules.evaluate(try evidence("fail")),
      ], durationMilliseconds: 12)

    #expect(result.tier.verdict == .red)
    #expect(result.tier.testCounts == (try TestCounts(passed: 2, failed: 2, skipped: 0)))
    #expect(result.findings.count == 2)
  }
}

@Suite("xUnit reports")
struct XUnitReportTests {
  @Test("parses Swift Testing skips with and without reasons — catches a skip counted as a pass")
  func swiftTestingSkips() throws {
    let cases = try XUnitReport.parse(try Fixture.data("SwiftTest/skip-swift-testing.xml"))

    #expect(
      cases.map(\.outcome) == [
        .skipped(reason: "flaky on CI"), .skipped(reason: nil),
      ])
    #expect(cases.map(\.targetName) == ["ProbeTests", "ProbeTests"])
  }

  @Test("a report truncated by a crash does not parse — catches a crashed run read as zero tests")
  func truncated() throws {
    #expect(throws: XUnitParseError.self) {
      try XUnitReport.parse(try Fixture.data("SwiftTest/crash-swift-testing.xml"))
    }
  }
}

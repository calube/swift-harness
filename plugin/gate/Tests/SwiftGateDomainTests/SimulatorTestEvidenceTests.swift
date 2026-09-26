import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("T2/T3 evidence rules")
struct SimulatorTestEvidenceTests {
  private static let target = TestTargetReference(
    name: "CounterUISnapshotTests",
    path: "examples/SampleApp/Packages/CounterFeature/Tests/CounterUISnapshotTests")
  private static let probeSource = "\(target.path)/XcresultProbeTests.swift"
  private static let sources = [probeSource, "\(target.path)/CounterViewSnapshotTests.swift"]

  /// A recorded `xcodebuild test` run; `succeeded` overrides the recorded exit status.
  private func evidence(
    _ scenario: String, tier: Tier = .t2, targets: [TestTargetReference] = [Self.target],
    succeeded: Bool? = nil, repositoryRoot: String = Fixture.repositoryRoot
  ) throws -> SimulatorTestEvidence {
    let status = try Fixture.text("Xcresult/\(scenario).status")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return SimulatorTestEvidence(
      tier: tier, testTargets: targets, succeeded: succeeded ?? (status == "0"),
      testResults: try Fixture.data("Xcresult/\(scenario).tests.json"),
      buildResults: try Fixture.data("Xcresult/\(scenario).build-results.json"),
      testSourceFiles: Self.sources, repositoryRoot: repositoryRoot)
  }

  private func evaluate(_ evidence: SimulatorTestEvidence) -> SimulatorTestOutcome {
    SimulatorTestEvidenceRules.evaluate(evidence)
  }

  @Test(
    "a passing snapshot test and XCTest case are GREEN with both counted — catches one framework's results being dropped from the tree walk"
  )
  func pass() throws {
    let outcome = evaluate(try evidence("pass"))

    #expect(outcome.verdict == .green)
    #expect(outcome.counts == (try TestCounts(passed: 2, failed: 0, skipped: 0)))
    #expect(outcome.findings.isEmpty)
  }

  @Test(
    "each failed case is RED at its assertion's file:line — catches failures reported without a location Claude can open"
  )
  func fail() throws {
    let outcome = evaluate(try evidence("fail"))

    #expect(outcome.verdict == .red)
    #expect(outcome.counts == (try TestCounts(passed: 1, failed: 2, skipped: 0)))
    let located = outcome.findings.map { "\($0.ruleID) \($0.file):\($0.line ?? 0)" }.sorted()
    #expect(
      located == [
        "t2.test-failed \(Self.probeSource):15", "t2.test-failed \(Self.probeSource):21",
      ])
    let messages = outcome.findings.map(\.message).sorted()
    #expect(
      messages == [
        "ProbeFailSwiftTests/multipliesWrong(): Expectation failed: (3 * 3 → 9) == 10",
        #"ProbeFailXCTests/testAddsWrong(): XCTAssertEqual failed: ("4") is not equal to ("5") - 2 + 2 should be 5"#,
      ])
  }

  @Test(
    "a skip without a reason is RED in both frameworks and a skip with one is not — catches reasonless XCTSkip and .disabled() hiding untested code"
  )
  func skip() throws {
    let outcome = evaluate(try evidence("skip"))

    #expect(outcome.verdict == .red)
    #expect(outcome.counts == (try TestCounts(passed: 0, failed: 0, skipped: 4)))
    let skips = outcome.findings.filter { $0.ruleID == "t2.skip-without-reason" }
    #expect(
      skips.map(\.message).sorted().map { String($0.prefix(while: { $0 != " " })) } == [
        "ProbeSkipSwiftTests/disabledWithoutReason()",
        "ProbeSkipXCTests/testSkippedWithoutReason()",
      ])
    #expect(skips.allSatisfy { $0.file == Self.target.path })
    // Skipped cases execute nothing, so the target also ran no tests.
    let noTests = outcome.findings.filter { $0.ruleID == "t2.no-tests" }
    #expect(noTests.map(\.file) == [Self.target.path])
  }

  @Test(
    "a crashing case is RED as a crash, located when the report names the line — catches a crash read as an ordinary assertion failure or as BLOCKED"
  )
  func crash() throws {
    let outcome = evaluate(try evidence("crash"))

    #expect(outcome.verdict == .red)
    #expect(outcome.counts == (try TestCounts(passed: 1, failed: 2, skipped: 0)))
    let crashes = outcome.findings.filter { $0.ruleID == "t2.crashed" }
    #expect(crashes.count == 2)
    let swiftTesting = try #require(
      crashes.first { $0.message.hasPrefix("ProbeCrashSwiftTests/crashes()") })
    #expect(swiftTesting.file == Self.probeSource && swiftTesting.line == 57)
    let xctest = try #require(
      crashes.first { $0.message.hasPrefix("ProbeCrashXCTests/testCrashes()") })
    #expect(xctest.file == Self.target.path && xctest.line == nil)
    #expect(xctest.message.contains("ProbeCrashXCTests.testCrashes()"))
  }

  @Test(
    "a run that executed no tests is RED per selected target — catches a filter matching nothing passing as GREEN"
  )
  func zero() throws {
    let outcome = evaluate(try evidence("zero"))

    #expect(outcome.verdict == .red)
    #expect(outcome.findings.map(\.ruleID) == ["t2.no-tests"])
    #expect(outcome.findings.first?.file == Self.target.path)
  }

  @Test(
    "a selected target absent from the results is RED even when others passed — catches a whole test bundle silently not running"
  )
  func missingTarget() throws {
    let uiTests = TestTargetReference(name: "SampleAppUITests", path: "examples/SampleApp/UITests")
    let outcome = evaluate(try evidence("pass", targets: [Self.target, uiTests]))

    #expect(outcome.verdict == .red)
    #expect(outcome.findings.map(\.ruleID) == ["t2.no-tests"])
    #expect(outcome.findings.first?.file == uiTests.path)
  }

  @Test(
    "an unavailable destination is BLOCKED with xcodebuild's reason — catches an environment failure being blamed on the code as no-tests"
  )
  func noDestination() throws {
    let outcome = evaluate(try evidence("no-destination"))

    #expect(outcome.verdict == .blocked)
    #expect(outcome.findings.map(\.ruleID) == ["t2.no-evidence"])
    let message = try #require(outcome.findings.first?.message)
    #expect(message.contains("Unable to find a device matching the provided destination"))
    #expect(!message.contains("Available destinations"))
  }

  @Test(
    "an unresolved destination without build results is still BLOCKED — catches a lost build log turning an environment failure into RED no-tests"
  )
  func noDestinationWithoutBuildResults() throws {
    let recorded = try evidence("no-destination")
    let outcome = evaluate(
      SimulatorTestEvidence(
        tier: .t2, testTargets: recorded.testTargets, succeeded: false,
        testResults: recorded.testResults, buildResults: nil,
        testSourceFiles: Self.sources, repositoryRoot: Fixture.repositoryRoot))

    #expect(outcome.verdict == .blocked)
    #expect(outcome.findings.map(\.ruleID) == ["t2.no-evidence"])
  }

  @Test(
    "a compile error in the repository is RED at its file:line — catches a broken test build reported as an environment problem"
  )
  func buildError() throws {
    let outcome = evaluate(
      try evidence(
        "build-error",
        targets: [
          TestTargetReference(
            name: "CounterUISnapshotTests",
            path: "CounterFeature/Tests/CounterUISnapshotTests")
        ],
        repositoryRoot: "/SCRATCH/Broken"))

    #expect(outcome.verdict == .red)
    #expect(outcome.findings.map(\.ruleID) == ["t2.build-failed"])
    let finding = try #require(outcome.findings.first)
    #expect(finding.file == "CounterFeature/Tests/CounterUISnapshotTests/XcresultProbeTests.swift")
    #expect(finding.line == 9)
    #expect(finding.message.contains("Type of expression is ambiguous"))
  }

  @Test(
    "a compile error outside the repository is BLOCKED — catches a dependency or toolchain break being blamed on the change"
  )
  func buildErrorOutsideRepository() throws {
    let outcome = evaluate(try evidence("build-error", repositoryRoot: "/elsewhere"))

    #expect(outcome.verdict == .blocked)
    #expect(outcome.findings.map(\.ruleID) == ["t2.no-evidence"])
  }

  @Test(
    "a nonzero exit whose results show no failure is BLOCKED — catches the exit code alone turning GREEN or RED"
  )
  func nonzeroExitWithoutFailures() throws {
    let outcome = evaluate(try evidence("pass", succeeded: false))

    #expect(outcome.verdict == .blocked)
    #expect(outcome.findings.map(\.ruleID) == ["t2.runner"])
  }

  @Test(
    "results that are not a test report are BLOCKED — catches an xcresulttool format change being read as zero tests"
  )
  func unreadable() throws {
    let outcome = evaluate(
      SimulatorTestEvidence(
        tier: .t2, testTargets: [Self.target], succeeded: true,
        testResults: Data(#"{"unexpected": true}"#.utf8), buildResults: nil,
        testSourceFiles: Self.sources, repositoryRoot: Fixture.repositoryRoot))

    #expect(outcome.verdict == .blocked)
    #expect(outcome.findings.map(\.ruleID) == ["t2.no-evidence"])
  }

  @Test(
    "T3 findings carry the t3 rule prefix and fold into a T3 tier — catches flow failures reported as T2"
  )
  func t3Tier() throws {
    let outcome = evaluate(try evidence("fail", tier: .t3))
    #expect(outcome.findings.allSatisfy { $0.ruleID.hasPrefix("t3.") })

    let (tier, findings) = try SimulatorTestEvidenceRules.tierResult(
      .t3, [outcome, evaluate(try evidence("pass", tier: .t3))], durationMilliseconds: 1200)
    #expect(tier.tier == .t3 && tier.verdict == .red)
    #expect(tier.testCounts == (try TestCounts(passed: 3, failed: 2, skipped: 0)))
    #expect(findings.count == 2)
  }

  @Test(
    "a result bundle that could not be read is BLOCKED — catches a missing .xcresult being judged as a code failure"
  )
  func unreadableBundle() {
    let outcome = SimulatorTestEvidenceRules.unreadable(
      tier: .t2, reason: "File or directory doesn't exist")

    #expect(outcome.verdict == .blocked)
    #expect(outcome.findings.map(\.ruleID) == ["t2.no-evidence"])
  }
}

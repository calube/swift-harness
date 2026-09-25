import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

@Suite("swiftgate coverage")
struct CoverageCommandTests {
  private static let probeSource = "XUnitProbe/Sources/Probe/Probe.swift"

  /// The recorded export, with its capture-time root rewritten to `root` (by default this
  /// repository's root as llvm-cov spells it).
  private func export(in repository: ProbeRepository, root: String? = nil) throws -> String {
    let text = try Fixture.text("SwiftTest/pass-codecov.json")
      .replacingOccurrences(
        of: "\(Fixture.repositoryRoot)/gate/Fixtures/swifttest",
        with: root ?? CanonicalPath.of(repository.root))
    let url = repository.root.appending(path: "codecov.json")
    try Data(text.utf8).write(to: url)
    return url.path
  }

  private func run(
    _ added: [ClosedRange<Int>], in repository: ProbeRepository, exportRoot: String? = nil
  ) async throws -> (GateRunParts, FakeSwiftPM) {
    let swiftPM = try ProbeRepository.swiftPM(
      replaying: "pass",
      coveragePaths: ["XUnitProbe": try export(in: repository, root: exportRoot)])
    let git = FakeGit(
      mergeBase: "base",
      addedSince: [AddedLines(path: Self.probeSource, ranges: added)])
    let parts = try await CoverageCheck.run(
      root: repository.root, swiftPM: swiftPM, git: git, base: "origin/main",
      context: repository.context())
    return (parts, swiftPM)
  }

  @Test(
    "changed Core lines no T1 test runs are RED against diff_coverage_min — catches untested logic passing push"
  )
  func uncovered() async throws {
    let repository = try ProbeRepository()
    defer { repository.remove() }

    let (parts, swiftPM) = try await run([5...10], in: repository)

    #expect(swiftPM.testRequests.map(\.codeCoverage) == [true])
    let report = try RunReport(
      runID: "r", durationMilliseconds: 1, tiers: parts.tiers, findings: parts.findings)
    #expect(report.verdict == .red)
    #expect(parts.findings.contains { $0.ruleID == DiffCoverage.ruleID })
    #expect(
      parts.findings.contains {
        $0.ruleID == DiffCoverage.uncoveredRuleID && $0.file == Self.probeSource && $0.line == 5
      })
  }

  @Test(
    "covered changed lines are GREEN and the ratio is reported — catches coverage passing without saying what it measured"
  )
  func covered() async throws {
    let repository = try ProbeRepository()
    defer { repository.remove() }

    let (parts, _) = try await run([1...3], in: repository)

    // The probe's EmptyTests target really is empty, so T1 itself is RED; coverage is not.
    let coverageFindings = parts.findings.filter { $0.ruleID.hasPrefix("coverage.") }
    #expect(!coverageFindings.contains { $0.severity.failsGate })
    let summary = try #require(parts.findings.first { $0.ruleID == CoverageCheck.summaryRuleID })
    #expect(summary.message.contains("3 of 3"))
  }

  @Test(
    "a repository in the temporary directory is matched although llvm-cov spells it /private/var/folders — catches every changed line reported uncovered for repositories under /var or /tmp"
  )
  func privateVarRoot() async throws {
    let repository = try ProbeRepository()
    defer { repository.remove() }
    // Foundation spells the temporary directory /var/folders/…; the compiler, llvm-cov and
    // swift package describe spell the same directory /private/var/folders/….
    #expect(repository.root.path.hasPrefix("/var/folders/"))

    let (parts, _) = try await run(
      [1...3], in: repository, exportRoot: "/private" + repository.root.path)

    let summary = try #require(parts.findings.first { $0.ruleID == CoverageCheck.summaryRuleID })
    #expect(summary.message.contains("3 of 3"))
    #expect(!parts.findings.contains { $0.ruleID == DiffCoverage.uncoveredRuleID })
  }

  @Test("a missing merge base is BLOCKED — catches coverage measured against no diff")
  func noMergeBase() async throws {
    let repository = try ProbeRepository()
    defer { repository.remove() }

    let parts = try await CoverageCheck.run(
      root: repository.root, swiftPM: try ProbeRepository.swiftPM(replaying: "pass"),
      git: FakeGit(mergeBase: nil), base: "origin/main", context: repository.context())

    let report = try RunReport(
      runID: "r", durationMilliseconds: 1, tiers: parts.tiers, findings: parts.findings)
    #expect(report.verdict == .blocked)
  }
}

import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

@Suite("swiftgate check")
struct CheckCommandTests {
  private func check(
    _ tier: CheckTier, in repository: ProbeRepository, swiftPM: FakeSwiftPM, git: FakeGit,
    formatter: FakeSwiftFormatter = FakeSwiftFormatter()
  ) async throws -> (parts: GateRunParts, report: RunReport) {
    let parts = try await CheckRun.run(
      root: repository.root, tier: tier, base: "origin/main", context: repository.context(),
      dependencies: CheckRun.Dependencies(
        root: repository.root, swiftPM: swiftPM, git: git, formatter: formatter,
        simulator: .fake))
    let report = try RunReport(
      runID: "r", durationMilliseconds: 1, tiers: parts.tiers, findings: parts.findings,
      allowances: parts.allowances)
    return (parts, report)
  }

  @Test(
    "fast runs T0 and only affected T1 packages, with no pending-step notes — catches the Stop-hook tier running the whole suite"
  )
  func fastUnaffected() async throws {
    let repository = try ProbeRepository()
    defer { repository.remove() }
    let swiftPM = try ProbeRepository.swiftPM(replaying: "pass")

    let (parts, report) = try await check(
      .fast, in: repository, swiftPM: swiftPM,
      git: FakeGit(changed: ["docs/guide.md"], mergeBase: "base"))

    #expect(parts.tiers.map(\.tier) == [.t0, .t1])
    #expect(swiftPM.testRequests.isEmpty)
    #expect(report.verdict == .green)
    #expect(!parts.findings.contains { $0.ruleID == CheckRun.notRunRuleID })
  }

  @Test(
    "fast tests the package a change affects, diffing from the merge base — catches a changed module's tests skipped by the fast tier"
  )
  func fastAffected() async throws {
    let repository = try ProbeRepository()
    defer { repository.remove() }
    let swiftPM = try ProbeRepository.swiftPM(replaying: "fail")
    let git = FakeGit(changed: ["XUnitProbe/Sources/Probe/Probe.swift"], mergeBase: "base")

    let (parts, report) = try await check(.fast, in: repository, swiftPM: swiftPM, git: git)

    #expect(git.changedSinceRefs == ["base"])
    #expect(swiftPM.testRequests.count == 1)
    #expect(report.verdict == .red)
    #expect(parts.findings.contains { $0.ruleID == HostTestEvidenceRules.failedRuleID })
  }

  @Test(
    "push runs every T1 target with coverage, impact and presence, and T2 on the affected packages — catches push skipping the simulator tier"
  )
  func push() async throws {
    let repository = try ProbeRepository()
    defer { repository.remove() }
    let swiftPM = try ProbeRepository.swiftPM(replaying: "pass")
    let git = FakeGit(changed: [], mergeBase: "base")

    let (parts, _) = try await check(.push, in: repository, swiftPM: swiftPM, git: git)

    #expect(swiftPM.testRequests.count == 1)
    #expect(!parts.findings.contains { $0.ruleID == CheckRun.notRunRuleID })
    // The probe has no simulator target, so T2 selects nothing and says so without failing.
    let t2 = parts.findings.filter { $0.ruleID == SimulatorTestCheck.nothingSelectedRuleID }
    #expect(t2.map(\.message).allSatisfy { $0.hasPrefix("T2:") })
    #expect(t2.count == 1 && t2.allSatisfy { !$0.severity.failsGate })
    // The probe's EmptyTests target is empty on purpose: evidence, not an exit code, says so.
    #expect(parts.findings.contains { $0.ruleID == HostTestEvidenceRules.noTestsRuleID })
  }

  @Test(
    "an Xcode pin mismatch ends T1, T2 and T3 BLOCKED with one doctor.xcode-pin finding, and T0 still runs — catches check reporting a build under the wrong toolchain as if the code were green"
  )
  func xcodePinMismatch() async throws {
    let repository = try ProbeRepository()
    defer { repository.remove() }
    let mismatched = SimulatorTestCheck.Dependencies(
      makeDevices: { _ in FakeDevices() },
      xcodebuild: FakeXcodebuild(versionOutput: "Xcode 25.0\nBuild version 1A1\n"),
      reader: FakeXcresultReader(scenario: "pass"))

    let parts = try await CheckRun.run(
      root: repository.root, tier: .ready, base: "origin/main", context: repository.context(),
      dependencies: CheckRun.Dependencies(
        root: repository.root, swiftPM: try ProbeRepository.swiftPM(replaying: "pass"),
        git: FakeGit(changed: [], mergeBase: "base"), formatter: FakeSwiftFormatter(),
        simulator: mismatched))

    #expect(parts.tiers.map(\.tier) == [.t0, .t1, .t2, .t3])
    #expect(parts.tiers.dropFirst().allSatisfy { $0.verdict == .blocked })
    let pinFindings = parts.findings.filter { $0.ruleID == Doctor.xcodePinRuleID }
    #expect(pinFindings.count == 1)
    #expect(pinFindings.first?.message.contains("25.0") == true)
    // T1 never ran, so nothing claims to have exercised its (empty, on purpose) test target.
    #expect(!parts.findings.contains { $0.ruleID == HostTestEvidenceRules.noTestsRuleID })
  }

  @Test("ready lists every step this build cannot run yet — catches ready silently equal to push")
  func ready() async throws {
    let repository = try ProbeRepository()
    defer { repository.remove() }

    let (parts, _) = try await check(
      .ready, in: repository, swiftPM: try ProbeRepository.swiftPM(replaying: "pass"),
      git: FakeGit(changed: [], mergeBase: "base"))

    let pending = CheckTier.ready.pendingSteps.map { "\($0.name) not run" }
    #expect(
      parts.findings.filter { finding in
        finding.ruleID == CheckRun.notRunRuleID
          && pending.contains { finding.message.hasPrefix($0) }
      }.count == pending.count)
    #expect(
      parts.findings.filter { $0.ruleID == SimulatorTestCheck.nothingSelectedRuleID }
        .map(\.message).sorted().map { $0.prefix(3) } == ["T2:", "T3:"])
  }

  @Test(
    "ready runs prove, stress and reach on the host tests instead of listing them as not run — catches ready claiming proofs it never ran"
  )
  func readyRunsChangedTestChecks() async throws {
    let repository = try ProbeRepository()
    defer { repository.remove() }
    let swiftPM = try ProbeRepository.swiftPM(replaying: "pass")
    let git = FakeGit(changed: [], mergeBase: "base")
    let scratch = FakeScratchWorktrees(root: repository.root)

    let parts = try await CheckRun.run(
      root: repository.root, tier: .ready, base: "origin/main", context: repository.context(),
      dependencies: CheckRun.Dependencies(
        root: repository.root, swiftPM: swiftPM, git: git, formatter: FakeSwiftFormatter(),
        simulator: .fake,
        changedTests: ChangedTestChecks.Environment(
          root: repository.root, git: git, swiftPM: swiftPM, scratch: scratch,
          scratchSwiftPM: { _ in swiftPM })))

    let notes = parts.findings.filter { $0.ruleID == ChangedTestChecks.summaryRuleID }
    #expect(notes.map(\.message).map { $0.prefix(6) } == ["reach:", "stress", "prove:"])
    let notRun = parts.findings.filter { $0.ruleID == CheckRun.notRunRuleID }.map(\.message)
    #expect(!notRun.contains { $0.hasPrefix("prove") || $0.hasPrefix("stress") })
  }

  @Test(
    "without a config T0 still runs and T1 is reported not run — catches check failing repositories that have not bootstrapped"
  )
  func noConfig() async throws {
    let repository = try ProbeRepository(config: nil)
    defer { repository.remove() }

    let (parts, report) = try await check(
      .fast, in: repository, swiftPM: try ProbeRepository.swiftPM(replaying: "pass"),
      git: FakeGit(changed: [], mergeBase: "base"))

    #expect(parts.tiers.map(\.tier) == [.t0])
    #expect(report.verdict == .green)
    #expect(parts.findings.contains { $0.ruleID == CheckRun.notRunRuleID })
  }

  @Test(
    "T0 format-lints only the changed Swift files still on disk and fails on a violation — catches unformatted code passing check"
  )
  func formatLintsChangedFiles() async throws {
    let repository = try ProbeRepository()
    defer { repository.remove() }
    try repository.write("XUnitProbe/Sources/Probe/Probe.swift", "public let probe = 1\n")
    try repository.write("XUnitProbe/Sources/Probe/Clean.swift", "public let clean = 1\n")
    try repository.write("XUnitProbe/.build/Generated.swift", "let generated = 1\n")
    let changed = [
      "XUnitProbe/Sources/Probe/Probe.swift", "XUnitProbe/Sources/Probe/Clean.swift",
      "XUnitProbe/.build/Generated.swift", "Deleted.swift", "docs/guide.md",
    ]
    let formatter = FakeSwiftFormatter(violations: [
      FormatViolation(
        path: "XUnitProbe/Sources/Probe/Probe.swift", line: 3, column: 1, rule: "Indentation",
        message: "unindent by 2 spaces")
    ])

    let (parts, report) = try await check(
      .fast, in: repository, swiftPM: try ProbeRepository.swiftPM(replaying: "pass"),
      git: FakeGit(changed: changed, mergeBase: "base"), formatter: formatter)

    #expect(
      formatter.lintedPaths
        == [["XUnitProbe/Sources/Probe/Clean.swift", "XUnitProbe/Sources/Probe/Probe.swift"]])
    let finding = try #require(parts.findings.first { $0.ruleID == "format.Indentation" })
    #expect(finding.file == "XUnitProbe/Sources/Probe/Probe.swift" && finding.line == 3)
    #expect(finding.severity.failsGate)
    #expect(parts.tiers.first { $0.tier == .t0 }?.verdict == .red)
    #expect(report.verdict == .red)
  }

  @Test(
    "a formatter that cannot run blocks T0 instead of passing or failing it — catches a missing toolchain read as clean"
  )
  func formatUnavailable() async throws {
    let repository = try ProbeRepository()
    defer { repository.remove() }
    try repository.write("Scripts/Tool.swift", "let tool = 1\n")

    let (parts, _) = try await check(
      .fast, in: repository, swiftPM: try ProbeRepository.swiftPM(replaying: "pass"),
      git: FakeGit(changed: ["Scripts/Tool.swift"], mergeBase: "base"),
      formatter: FakeSwiftFormatter(
        failure: .process(.launchFailed(executable: "swift", reason: "not found"))))

    #expect(parts.tiers.first { $0.tier == .t0 }?.verdict == .blocked)
  }

  @Test(
    "a merge base git can't resolve names the fix, not a raw git error — catches no-origin/main reported with no guidance"
  )
  func changedSinceMergeBaseNamesTheFix() async {
    let git = FakeGit(
      failure: .commandFailed(
        arguments: ["merge-base", "HEAD", "origin/main"], status: .exited(128),
        stderr: "fatal: Not a valid object name origin/main\n"))

    let result = await CheckRun.changedSinceMergeBase(git: git, base: "origin/main")

    guard case .failure(let reason) = result else {
      Issue.record("expected a blocked reason, got \(result)")
      return
    }
    #expect(reason.text.contains("pass --base <ref>"))
    #expect(
      !reason.text.hasPrefix("git: commandFailed"), "should not be a raw, unexplained git error")
  }

  @Test(
    "--tier parses fast, push and ready and --base defaults to origin/main — catches an unknown tier running as fast"
  )
  func parsing() throws {
    let command = try #require(
      try SwiftGate.parseAsRoot(["check", "--tier", "push"]) as? CheckCommand)
    #expect(command.tier == .push)
    #expect(command.base == "origin/main")
    #expect(throws: (any Error).self) { try SwiftGate.parseAsRoot(["check", "--tier", "slow"]) }
  }
}

@Suite("swiftgate stats")
struct StatsCommandTests {
  @Test(
    "renders p50/p95 per command and tier and marks rows over budget — catches a budget breach invisible in stats"
  )
  func render() throws {
    let rows = [
      TierStats(
        command: "check fast", tier: .t1, runs: 3, p50Milliseconds: 2_000,
        p95Milliseconds: 70_000, budgetMilliseconds: 60_000, verdicts: [.green: 2, .red: 1])
    ]

    let text = StatsRenderer.human(rows, invalidLines: 1)

    #expect(text.contains("check fast"))
    #expect(text.contains("2.0s") && text.contains("70.0s") && text.contains("OVER"))
    #expect(text.contains("1 unreadable history line"))
  }
}

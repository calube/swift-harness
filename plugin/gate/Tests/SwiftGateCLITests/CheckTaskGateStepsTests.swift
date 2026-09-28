import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// `check --tier fast --impact --coverage --app-build`: a build task's gate catches what the merge
/// gate would otherwise find only after the merge, while plain `fast` keeps the hooks' speed.
@Suite("check: a task gate's impact, coverage and app build")
struct CheckTaskGateStepsTests {
  private static let source = "XUnitProbe/Sources/Probe/Probe.swift"
  private static let matchingVersion = "Xcode 26.2.1\nBuild version 17C48\n"

  private struct Run {
    let parts: GateRunParts
    let verdict: Verdict
    let swiftPM: FakeSwiftPM
    let xcodebuild: FakeXcodebuild

    func has(_ ruleID: String) -> Bool { parts.findings.contains { $0.ruleID == ruleID } }
    func gates(_ ruleID: String) -> Bool {
      parts.findings.contains { $0.ruleID == ruleID && $0.severity.failsGate }
    }
    var notRun: [String] {
      parts.findings.filter { $0.ruleID == CheckRun.notRunRuleID }.map(\.message)
    }
  }

  /// The recorded llvm-cov export, rewritten to `repository`'s root.
  private static func export(in repository: ProbeRepository) throws -> String {
    let text = try Fixture.text("SwiftTest/pass-codecov.json")
      .replacingOccurrences(
        of: "\(Fixture.repositoryRoot)/gate/Fixtures/swifttest",
        with: CanonicalPath.of(repository.root))
    let url = repository.root.appending(path: "codecov.json")
    try Data(text.utf8).write(to: url)
    return url.path
  }

  /// A `fast` run over a change to the probe's source whose added lines no test covers. With
  /// `appContainer`, the repository holds an app project whose build exits `buildStatus`.
  private static func fast(
    steps: Set<CheckRun.ExtraStep>, changed: [String] = [source], scenario: String = "pass",
    appContainer: String? = nil, buildStatus: SwiftGateAdapters.ExitStatus = .exited(65),
    buildResults: String = "app-build-error", formatViolation: Bool = false
  ) async throws -> Run {
    let repository = try ProbeRepository()
    defer { repository.remove() }
    if let appContainer {
      try FileManager.default.createDirectory(
        at: repository.root.appending(path: appContainer), withIntermediateDirectories: true)
    }
    let swiftPM = try ProbeRepository.swiftPM(
      replaying: scenario, coveragePaths: ["XUnitProbe": try export(in: repository)])
    let git = FakeGit(
      changed: changed, mergeBase: "base",
      addedSince: changed.map { AddedLines(path: $0, ranges: [5...10]) })
    let xcodebuild = FakeXcodebuild(buildStatus: buildStatus, versionOutput: matchingVersion)
    let formatter = FakeSwiftFormatter(
      violations: formatViolation
        ? [
          FormatViolation(
            path: source, line: 1, column: 1, rule: "Indentation", message: "unindent by 2 spaces")
        ] : [])
    if formatViolation { try repository.write(source, "public let probe = 1\n") }

    let parts = try await CheckRun.run(
      root: repository.root, tier: .fast, base: "main", extraSteps: steps,
      context: repository.context(),
      dependencies: CheckRun.Dependencies(
        root: repository.root, swiftPM: swiftPM, git: git, formatter: formatter,
        simulator: SimulatorTestCheck.Dependencies(
          makeDevices: { _ in FakeDevices() }, xcodebuild: xcodebuild,
          reader: FakeXcresultReader(scenario: buildResults))))
    let report = try RunReport(
      runID: "r", durationMilliseconds: 1, tiers: parts.tiers, findings: parts.findings,
      allowances: parts.allowances)
    return Run(parts: parts, verdict: report.verdict, swiftPM: swiftPM, xcodebuild: xcodebuild)
  }

  @Test(
    "a task gate over an untested Core change is RED on impact where plain fast is not — catches a green task gate followed by a red merge gate on impact"
  )
  func impactCatchesAnUntestedChange() async throws {
    let plain = try await Self.fast(steps: [])
    let gated = try await Self.fast(steps: [.impact])

    #expect(!plain.has(ImpactAnalysis.ruleID))
    #expect(gated.gates(ImpactAnalysis.ruleID))
    #expect(gated.verdict == .red)
  }

  @Test(
    "a task gate over uncovered added Core lines is RED on diff coverage where plain fast is not — catches a green task gate followed by a red merge gate on coverage"
  )
  func coverageCatchesUncoveredLines() async throws {
    let plain = try await Self.fast(steps: [])
    let gated = try await Self.fast(steps: [.coverage])

    #expect(!plain.has(DiffCoverage.ruleID))
    #expect(gated.gates(DiffCoverage.ruleID))
  }

  @Test(
    "a change that breaks the app target's compile is RED at the task gate, and plain fast never builds the app — catches a view the host build compiles out breaking only after the merge"
  )
  func appBuildCatchesABrokenAppTarget() async throws {
    let plain = try await Self.fast(steps: [], changed: [], appContainer: "Probe.xcodeproj")
    let broken = try await Self.fast(
      steps: [.appBuild], changed: [], appContainer: "Probe.xcodeproj")

    #expect(plain.xcodebuild.buildRequests.isEmpty)
    #expect(plain.verdict == .green)
    let request = try #require(broken.xcodebuild.buildRequests.first)
    #expect(broken.xcodebuild.buildRequests.count == 1)
    #expect(request.scheme == "Probe")
    guard case .project(let path) = request.container else {
      Issue.record("expected the root project, got \(request.container)")
      return
    }
    #expect(path.hasSuffix("/Probe.xcodeproj"))
    #expect(broken.gates(AppBuild.errorRuleID))
    #expect(broken.verdict == .red)
  }

  @Test(
    "an app that builds keeps the task gate GREEN with a summary, and a repository with no app container notes the step not run — catches the app build failing package-only repositories or passing silently"
  )
  func appBuildGreenOrNotApplicable() async throws {
    let built = try await Self.fast(
      steps: [.appBuild], changed: [], appContainer: "Probe.xcworkspace",
      buildStatus: .exited(0), buildResults: "app-build-pass")
    let packageOnly = try await Self.fast(steps: [.appBuild], changed: [])

    #expect(built.verdict == .green)
    #expect(built.has(AppBuild.summaryRuleID))
    #expect(packageOnly.xcodebuild.buildRequests.isEmpty)
    #expect(packageOnly.verdict == .green)
    #expect(packageOnly.notRun.contains { $0.hasPrefix("app build not run: no .xcworkspace") })
  }

  @Test(
    "a RED T0 skips coverage and the app build with a note each, and a RED T1 skips the app build — catches a task gate that builds the app after a failure already decided it"
  )
  func failFastSkipsTheNewSteps() async throws {
    let redT0 = try await Self.fast(
      steps: [.coverage, .appBuild], appContainer: "Probe.xcodeproj", formatViolation: true)
    let redT1 = try await Self.fast(
      steps: [.appBuild], scenario: "fail", appContainer: "Probe.xcodeproj")

    #expect(
      redT0.notRun == [
        "T1 not run: T0 is RED", "coverage not run: T0 is RED", "app build not run: T0 is RED",
      ])
    #expect(redT0.xcodebuild.buildRequests.isEmpty)
    #expect(redT1.notRun.contains("app build not run: T1 is RED"))
    #expect(redT1.xcodebuild.buildRequests.isEmpty)
    #expect(redT1.verdict == .red)
  }

  @Test(
    "the flags ask for each step, and a tier that runs a step anyway doesn't record it as extra — catches --app-build dropped between the flag and the run"
  )
  func flagsBecomeSteps() throws {
    let fast = try CheckCommand.parse([
      "--tier", "fast", "--prove", "--impact", "--coverage", "--app-build",
    ])
    let push = try CheckCommand.parse(["--tier", "push", "--impact", "--coverage", "--app-build"])
    let plain = try CheckCommand.parse(["--tier", "fast"])

    #expect(fast.extraSteps == [.prove, .impact, .coverage, .appBuild])
    #expect(push.extraSteps == [.appBuild])
    #expect(plain.extraSteps.isEmpty)
  }
}

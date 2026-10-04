import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("check extra steps")
struct CheckExtraStepTests {
  @Test(
    "fast runs impact and coverage only when a step asks for each, push always — catches a task gate that drops the impact or coverage it asked for"
  )
  func impactAndCoverageFollowTheSteps() {
    #expect(!CheckTier.fast.runsImpact(with: []))
    #expect(!CheckTier.fast.runsCoverage(with: []))
    #expect(CheckTier.fast.runsImpact(with: [.impact]))
    #expect(!CheckTier.fast.runsCoverage(with: [.impact]))
    #expect(CheckTier.fast.runsCoverage(with: [.coverage]))
    #expect(!CheckTier.fast.runsImpact(with: [.coverage, .appBuild]))
    #expect(CheckTier.push.runsImpact(with: []) && CheckTier.push.runsCoverage(with: []))
  }

  @Test(
    "impact and coverage are extra only at fast, app-build at every tier — catches a push gate recording a step it runs anyway, or a ready gate dropping the app build"
  )
  func whichTiersRunEachStep() {
    #expect(!CheckExtraStep.impact.isRun(by: .fast))
    #expect(CheckExtraStep.impact.isRun(by: .push))
    #expect(!CheckExtraStep.coverage.isRun(by: .fast))
    #expect(CheckExtraStep.coverage.isRun(by: .ready))
    #expect(!CheckExtraStep.prove.isRun(by: .push))
    #expect(CheckExtraStep.mutate.isRun(by: .ready))
    #expect(CheckTier.allCases.allSatisfy { !CheckExtraStep.appBuild.isRun(by: $0) })
  }
}

@Suite("app build")
struct AppBuildTests {
  @Test(
    "the build request is a closed argv: build for a generic simulator with macro validation skipped and only the resolved pins — catches an app build that stalls on macro trust or rewrites Package.resolved"
  )
  func requestArguments() {
    let workspace = AppBuild.Request(
      container: .workspace(path: "/r/App.xcworkspace"), scheme: "App",
      derivedDataPath: "/r/.harness/derived-data/app-build", resultBundlePath: "/o/App.xcresult")
    let project = AppBuild.Request(
      container: .project(path: "/r/App.xcodeproj"), scheme: "App", derivedDataPath: "/d",
      resultBundlePath: "/b")

    #expect(
      workspace.arguments == [
        "build", "-quiet", "-workspace", "/r/App.xcworkspace", "-scheme", "App",
        "-destination", "generic/platform=iOS Simulator",
        "-derivedDataPath", "/r/.harness/derived-data/app-build",
        "-resultBundlePath", "/o/App.xcresult",
        "-skipMacroValidation", "-skipPackagePluginValidation",
        "-onlyUsePackageVersionsFromResolvedFile",
      ])
    #expect(project.arguments.starts(with: ["build", "-quiet", "-project", "/r/App.xcodeproj"]))
  }

  @Test(
    "a failed app build is RED with each compiler error at its repository-relative file and line — catches a view the host build compiles out breaking only after the merge"
  )
  func failedBuildIsRed() throws {
    let results = try Fixture.data("Xcresult/app-build-error.build-results.json")
    let judgement = try AppBuild.judge(
      scheme: "SampleApp", succeeded: false, buildResults: results,
      repositoryRoot: "/SCRATCH/SampleApp")
    // The root's real path, which xcodebuild spells without `/private`.
    let realPath = try AppBuild.judge(
      scheme: "SampleApp", succeeded: false, buildResults: results,
      repositoryRoot: "/private/SCRATCH/SampleApp")

    #expect(judgement.verdict == .red)
    let errors = judgement.findings.filter { $0.ruleID == AppBuild.errorRuleID }
    #expect(errors.count == 1 && errors.allSatisfy { $0.severity.failsGate })
    #expect(errors.first?.file == "App/SampleApp.swift")
    #expect(errors.first?.line == 23)
    #expect(errors.first?.message.contains("Cannot convert value of type 'String'") == true)
    #expect(realPath.findings.map(\.file) == ["App/SampleApp.swift"])
  }

  @Test(
    "a built app is GREEN with a summary naming the scheme — catches an app build passing without saying what it compiled"
  )
  func builtAppIsGreen() throws {
    let judgement = try AppBuild.judge(
      scheme: "SampleApp", succeeded: true,
      buildResults: try Fixture.data("Xcresult/app-build-pass.build-results.json"),
      repositoryRoot: "/SCRATCH/SampleApp")

    #expect(judgement.verdict == .green)
    #expect(judgement.findings.map(\.ruleID) == [AppBuild.summaryRuleID])
    #expect(judgement.findings.first?.message.contains("SampleApp") == true)
  }

  @Test(
    "a failed build with no readable build results is BLOCKED, never GREEN — catches an unreadable bundle passing the app build"
  )
  func failedWithoutEvidenceIsBlocked() throws {
    let judgement = try AppBuild.judge(
      scheme: "SampleApp", succeeded: false, buildResults: nil, repositoryRoot: "/SCRATCH")

    #expect(judgement.verdict == .blocked)
    #expect(judgement.findings.map(\.ruleID) == [AppBuild.blockedRuleID])
  }
}

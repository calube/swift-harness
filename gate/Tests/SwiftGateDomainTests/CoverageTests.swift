import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("Line coverage")
struct LineCoverageTests {
  private static let probe = "gate/Fixtures/swifttest/XUnitProbe/Sources/Probe/Probe.swift"

  @Test(
    "reads executable and covered lines from llvm-cov segments — catches blank or closing lines counted, or an uncalled function counted covered"
  )
  func probeLines() throws {
    let coverage = try LineCoverage(
      llvmExport: Fixture.data("SwiftTest/pass-codecov.json"),
      repositoryRoot: Fixture.repositoryRoot)

    let file = try #require(coverage.files[Self.probe])
    #expect(file.executable == [1, 2, 3, 5, 6, 7, 8, 9, 10])
    #expect(file.covered == [1, 2, 3])
  }

  @Test(
    "only files inside the repository and outside build output are kept — catches dependency checkouts counted as changed code"
  )
  func scopedToRepository() throws {
    let coverage = try LineCoverage(
      llvmExport: Fixture.data("SwiftTest/pass-codecov.json"),
      repositoryRoot: Fixture.repositoryRoot)

    #expect(coverage.files.keys.allSatisfy { !$0.hasPrefix("/") && !$0.contains(".build/") })
    #expect(coverage.files.count == 5)
  }

  @Test(
    "merging keeps a line covered if any package's run covered it — catches a dependent package's tests ignored"
  )
  func merge() {
    let a = LineCoverage(files: ["F.swift": FileLineCoverage(executable: [1, 2, 3], covered: [1])])
    let b = LineCoverage(files: ["F.swift": FileLineCoverage(executable: [2, 3], covered: [3])])

    #expect(
      a.merged(with: b).files["F.swift"]
        == FileLineCoverage(executable: [1, 2, 3], covered: [1, 3]))
  }

  @Test("a malformed export does not parse — catches a truncated export read as zero coverage")
  func malformed() {
    #expect(throws: CoverageParseError.self) {
      try LineCoverage(llvmExport: Data("{\"data\": 3}".utf8), repositoryRoot: "/REPO")
    }
  }
}

@Suite("Diff coverage")
struct DiffCoverageTests {
  private let engine = "examples/SampleApp/Packages/GameEngine/Sources/GameEngine/GameEngine.swift"
  private let ui = "examples/SampleApp/Packages/CounterFeature/Sources/CounterUI/CounterView.swift"
  private let test =
    "examples/SampleApp/Packages/GameEngine/Tests/GameEngineTests/GameEngineRulesTests.swift"

  private func evaluate(_ added: [AddedLines], _ coverage: LineCoverage, minimum: Double = 0.9)
    throws -> DiffCoverageResult
  {
    try DiffCoverage.evaluate(
      addedLines: added, scopes: SampleGraph.graph(), coverage: coverage, minimum: minimum)
  }

  @Test(
    "changed Core lines below the minimum are RED with the uncovered lines — catches untested logic merging"
  )
  func belowMinimum() throws {
    let coverage = LineCoverage(files: [
      engine: FileLineCoverage(executable: [10, 11, 12, 13], covered: [10])
    ])

    let result = try evaluate([AddedLines(path: engine, ranges: [9...13])], coverage)

    #expect(result.measured == 4)
    #expect(result.covered == 1)
    #expect(result.verdict == .red)
    let uncovered = try #require(
      result.findings.first { $0.ruleID == DiffCoverage.uncoveredRuleID })
    #expect(uncovered.file == engine)
    #expect(uncovered.line == 11)
    #expect(uncovered.message.contains("11-13"))
    #expect(result.findings.contains { $0.ruleID == DiffCoverage.ruleID && $0.severity.failsGate })
  }

  @Test(
    "covered changes, and changes to UI or test files, are GREEN — catches coverage demanded where T1 cannot reach"
  )
  func greenAndOutOfScope() throws {
    let coverage = LineCoverage(files: [
      engine: FileLineCoverage(executable: [10, 11], covered: [10, 11]),
      ui: FileLineCoverage(executable: [1, 2], covered: []),
      test: FileLineCoverage(executable: [1], covered: []),
    ])

    let result = try evaluate(
      [
        AddedLines(path: engine, ranges: [10...11]), AddedLines(path: ui, ranges: [1...2]),
        AddedLines(path: test, ranges: [1...1]),
      ], coverage)

    #expect(result.measured == 2)
    #expect(result.verdict == .green)
    #expect(result.findings.isEmpty)
  }

  @Test(
    "a changed Core file no T1 run compiled is reported, not silently skipped — catches coverage passing because the file was never built"
  )
  func missingFile() throws {
    let result = try evaluate([AddedLines(path: engine, ranges: [1...3])], LineCoverage(files: [:]))

    #expect(result.findings.map(\.ruleID) == [DiffCoverage.noDataRuleID])
    #expect(result.measured == 0)
  }
}

@Suite("T1 presence")
struct T1PresenceTests {
  @Test(
    "a Core, client or Live module with no host test target is RED — catches a module whose logic only simulator tests reach"
  )
  func sampleGraph() throws {
    let findings = try T1Presence.evaluate(SampleGraph.graph())

    #expect(findings.map(\.ruleID) == [T1Presence.ruleID])
    #expect(findings.first?.message.contains("APIClient ") == true)
    #expect(findings.first?.file == "examples/SampleApp/Packages/APIClient/Sources/APIClient")
  }

  @Test(
    "a module declared not host-testable is exempt — catches presence demanding T1 tests that cannot compile on the host"
  )
  func notHostTestable() throws {
    let config = try SampleGraph.config(modules: [
      ModuleOverride(name: "GameEngine", hostTestable: false, reason: "Metal types in its API")
    ])

    let findings = try T1Presence.evaluate(SampleGraph.graph(config: config))

    #expect(findings.map(\.file) == ["examples/SampleApp/Packages/APIClient/Sources/APIClient"])
  }
}

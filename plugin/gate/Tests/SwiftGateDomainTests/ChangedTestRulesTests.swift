import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("Changed tests: ids, filters and report matching")
struct ChangedTestTests {
  @Test(
    "ids and filters follow swift test list for nested suites, free functions and XCTest — catches a filter that selects no test or the wrong one"
  )
  func idsAndFilters() {
    let nested = ChangedTest(
      framework: .swiftTesting, target: "LibTests", suites: ["Outer", "Inner"],
      function: "nested()", file: "T.swift", line: 1)
    let free = ChangedTest(
      framework: .swiftTesting, target: "LibTests", suites: [], function: "freeFunction()",
      file: "T.swift", line: 1)
    let xctest = ChangedTest(
      framework: .xcTest, target: "LibTests", suites: ["XC"], function: "testDouble",
      file: "T.swift", line: 1)

    #expect(nested.id == "LibTests.Outer/Inner/nested()")
    #expect(free.id == "LibTests.freeFunction()")
    #expect(xctest.id == "LibTests.XC/testDouble")
    #expect(nested.filter == #"^LibTests\.Outer/Inner/nested\(\)"#)
    #expect(xctest.filter == #"^LibTests\.XC/testDouble$"#)
    #expect(
      ChangedTest.filter(selecting: [free, xctest])
        == #"(^LibTests\.freeFunction\(\)|^LibTests\.XC/testDouble$)"#)
  }

  @Test(
    "a test matches its xUnit case by dotted class name and function — catches a nested suite's result read as missing"
  )
  func matchesReportCases() {
    let nested = ChangedTest(
      framework: .swiftTesting, target: "LibTests", suites: ["Outer", "Inner"],
      function: "nested()", file: "T.swift", line: 1)
    let free = ChangedTest(
      framework: .swiftTesting, target: "LibTests", suites: [], function: "freeFunction()",
      file: "T.swift", line: 1)

    #expect(
      nested.matches(
        XUnitTestCase(className: "LibTests.Outer.Inner", name: "nested()", outcome: .passed)))
    #expect(
      !nested.matches(
        XUnitTestCase(className: "LibTests.Outer", name: "nested()", outcome: .passed)))
    #expect(
      free.matches(XUnitTestCase(className: "LibTests", name: "freeFunction()", outcome: .passed)))
  }
}

@Suite("prove, stress and reach rules")
struct ChangedTestRulesTests {
  private let tests = [ProbeRun.passXCTest, ProbeRun.passSwiftTesting]

  private func observe(_ scenario: String, _ tests: [ChangedTest]? = nil) throws
    -> SelectedTestRun
  {
    SelectedTestRun.observe(tests ?? self.tests, in: try ProbeRun.evidence(scenario))
  }

  @Test(
    "tests that fail on assertions with the source reverted are proven and GREEN — catches a real red/green proof reported as a failure"
  )
  func proven() throws {
    let (judgement, proven) = ProofRules.judgeReverted(
      tests, run: try observe("reverted"), testDirectories: [ProbeRun.testDirectory])

    #expect(judgement.verdict == .green)
    #expect(judgement.findings.isEmpty)
    #expect(proven == tests)
  }

  @Test(
    "a test that still passes with the source reverted is RED not-proven at its declaration — catches a test that does not test the change"
  )
  func notProven() throws {
    let (judgement, proven) = ProofRules.judgeReverted(
      tests, run: try observe("pass"), testDirectories: [ProbeRun.testDirectory])

    #expect(judgement.verdict == .red)
    #expect(proven.isEmpty)
    #expect(
      judgement.findings.map(\.ruleID) == Array(repeating: ProofRules.notProvenRuleID, count: 2))
    #expect(judgement.findings.map(\.line) == [6, 12])
  }

  @Test(
    "tests that only fail to compile with the source reverted are RED compile-only, citing the compile error — catches a compile failure counted as a proof"
  )
  func compileOnly() throws {
    let (judgement, proven) = ProofRules.judgeReverted(
      tests, run: try observe("compile-only"), testDirectories: [ProbeRun.testDirectory])

    #expect(judgement.verdict == .red)
    #expect(proven.isEmpty)
    #expect(judgement.findings.allSatisfy { $0.ruleID == ProofRules.compileOnlyRuleID })
    #expect(judgement.findings.count == 2)
    #expect(judgement.findings.first?.message.contains("not proven: compile-only") == true)
    #expect(judgement.findings.first?.message.contains("cannot find 'double' in scope") == true)
  }

  private func attempt(_ base: String, _ scenario: String, _ tests: [ChangedTest]) throws
    -> ProofRules.RevertedAttempt
  {
    let (judgement, proven) = ProofRules.judgeReverted(
      tests, run: try observe(scenario, tests), testDirectories: [ProbeRun.testDirectory])
    return ProofRules.RevertedAttempt(
      base: base, tests: tests, judgement: judgement, proven: proven)
  }

  @Test(
    "tests compile-only at the merge base that fail on an assertion at a proof base are proven and GREEN — catches a new-API test that can never be proven"
  )
  func compileOnlyThenProvenAtProofBase() throws {
    let atMergeBase = try attempt("mergebase", "compile-only", tests)

    let combined = ProofRules.combine([
      atMergeBase,
      try attempt("surface", "reverted", ProofRules.compileOnly(tests, in: atMergeBase.judgement)),
    ])

    #expect(combined.judgement.verdict == .green)
    #expect(combined.judgement.findings.isEmpty)
    #expect(combined.proven == tests)
    #expect(combined.provenAtProofBase == 2)
  }

  @Test(
    "a test compile-only at the merge base that passes at the proof base is not-proven, with no compile-only left — catches a proof base hiding a test that checks nothing"
  )
  func compileOnlyThenPassesAtProofBase() throws {
    let atMergeBase = try attempt("mergebase", "compile-only", tests)

    let combined = ProofRules.combine([
      atMergeBase,
      try attempt("surface", "pass", ProofRules.compileOnly(tests, in: atMergeBase.judgement)),
    ])

    #expect(combined.judgement.verdict == .red)
    #expect(combined.proven.isEmpty)
    #expect(
      combined.judgement.findings.map(\.ruleID)
        == Array(repeating: ProofRules.notProvenRuleID, count: 2))
  }

  @Test(
    "a compile-only test no proof base retried keeps its merge-base finding — catches a retry of one test clearing another's"
  )
  func unretriedTestKeepsItsFinding() throws {
    let atMergeBase = try attempt("mergebase", "compile-only", tests)

    let combined = ProofRules.combine([
      atMergeBase, try attempt("surface", "reverted", [tests[0]]),
    ])

    #expect(combined.judgement.verdict == .red)
    #expect(combined.proven == [tests[0]])
    #expect(combined.judgement.findings.map(\.ruleID) == [ProofRules.compileOnlyRuleID])
    #expect(combined.judgement.findings.map(\.line) == [tests[1].line])
  }

  @Test(
    "a reverted run that loaded no package is retried in full at the next proof base, and compile-only tests alone otherwise — catches a package emptied at the merge base never tried where its stubs exist"
  )
  func noEvidenceRunIsRetried() throws {
    let emptied = try attempt("mergebase", "emptied-target", tests)
    let compileOnly = try attempt("mergebase", "compile-only", [tests[0]])
    let proven = try attempt("mergebase", "reverted", tests)

    #expect(emptied.judgement.verdict == .blocked)
    #expect(ProofRules.retryable(tests, in: emptied.judgement) == tests)
    #expect(ProofRules.retryable(tests, in: compileOnly.judgement) == [tests[0]])
    #expect(ProofRules.retryable(tests, in: proven.judgement).isEmpty)
  }

  @Test(
    "a merge base with no evidence and a proof base that proves every test is GREEN with no finding — catches a stale blocked flag or package-level finding outliving the retry"
  )
  func blockedMergeBaseThenProvenAtProofBase() throws {
    let combined = ProofRules.combine([
      try attempt("mergebase", "emptied-target", tests),
      try attempt("surface", "reverted", tests),
    ])

    #expect(combined.judgement.verdict == .green)
    #expect(combined.judgement.findings.isEmpty)
    #expect(combined.proven == tests)
    #expect(combined.provenAtProofBase == 2)
  }

  @Test(
    "a target emptied at the last base tried is RED compile-only per test, pointing at --proof-base, never BLOCKED — catches a missing surface commit read as an environment failure"
  )
  func emptiedTargetWithNoProofBaseLeft() throws {
    let combined = ProofRules.combine([try attempt("mergebase", "emptied-target", tests)])

    #expect(combined.judgement.verdict == .red)
    #expect(
      combined.judgement.findings.map(\.ruleID)
        == Array(repeating: ProofRules.compileOnlyRuleID, count: 2))
    #expect(combined.judgement.findings.map(\.line) == tests.map(\.line))
    #expect(
      combined.judgement.findings.allSatisfy {
        $0.message.contains("target 'Probe' referenced in product 'Probe' is empty")
          && $0.message.contains("pass that commit as --proof-base")
      })
  }

  @Test(
    "an environment failure at the merge base and at every proof base stays BLOCKED — catches a retry that forgives a broken environment"
  )
  func environmentFailureAtEveryBase() throws {
    let combined = ProofRules.combine([
      try attempt("mergebase", "stale-module-cache", tests),
      try attempt("surface", "stale-module-cache", tests),
    ])

    #expect(combined.judgement.verdict == .blocked)
    #expect(combined.judgement.findings.map(\.ruleID) == [ProofRules.noEvidenceRuleID])
    #expect(combined.proven.isEmpty)
  }

  @Test(
    "a test whose own declaration compiles, blocked by another test's compile error, is not proven with that cause named — catches one new-API test blamed on every test"
  )
  func compileBlockedByAnotherTest() throws {
    let bystander = ChangedTest(
      framework: .swiftTesting, target: "ProbeTests", suites: ["CrashSwiftTests"],
      function: "crashes()", file: "\(ProbeRun.testDirectory)/CrashTests.swift", line: 12,
      lastLine: 15)
    let (judgement, _) = ProofRules.judgeReverted(
      [bystander], run: try observe("compile-only", [bystander]),
      testDirectories: [ProbeRun.testDirectory])

    #expect(judgement.findings.map(\.ruleID) == [ProofRules.compileOnlyRuleID])
    #expect(
      judgement.findings.first?.message.contains("another test in the build does not compile")
        == true)
  }

  @Test(
    "a compile error outside the test targets with the source reverted is BLOCKED — catches a broken revert blamed on the tests"
  )
  func revertedTreeBroken() throws {
    let (judgement, _) = ProofRules.judgeReverted(
      tests, run: try observe("build-error"), testDirectories: [ProbeRun.testDirectory])

    #expect(judgement.verdict == .blocked)
    #expect(judgement.findings.map(\.ruleID) == [ProofRules.noEvidenceRuleID])
  }

  @Test(
    "a crash with the source reverted is RED crashed, not proven — catches a crash accepted in place of an assertion"
  )
  func crashed() throws {
    let crashing = ChangedTest(
      framework: .swiftTesting, target: "ProbeTests", suites: ["CrashSwiftTests"],
      function: "crashes()", file: "\(ProbeRun.testDirectory)/CrashTests.swift", line: 12)
    let (judgement, proven) = ProofRules.judgeReverted(
      [crashing], run: try observe("crash", [crashing]),
      testDirectories: [ProbeRun.testDirectory])

    #expect(judgement.verdict == .red)
    #expect(proven.isEmpty)
    #expect(judgement.findings.map(\.ruleID) == [ProofRules.crashedRuleID])
  }

  @Test(
    "a changed test that fails with the change applied is RED fails-at-head — catches a failing test counted as proven because it also fails reverted"
  )
  func failsWithChange() throws {
    let judgement = ProofRules.judgeChange(
      [ProbeRun.failSwiftTesting], run: try observe("fail", [ProbeRun.failSwiftTesting]))

    #expect(judgement.verdict == .red)
    #expect(judgement.findings.map(\.ruleID) == [ProofRules.failsAtHeadRuleID])
  }

  @Test(
    "a test absent from the report is BLOCKED, not proven or passed — catches a filter that matched nothing reading as success"
  )
  func missingFromReport() throws {
    let judgement = ProofRules.judgeChange(
      [ProbeRun.failSwiftTesting], run: try observe("pass", [ProbeRun.failSwiftTesting]))

    #expect(judgement.verdict == .blocked)
    #expect(judgement.findings.map(\.ruleID) == [ProofRules.noEvidenceRuleID])
  }

  @Test(
    "one failure across N stress runs is RED with the failure count — catches a flaky test hidden by later passes"
  )
  func stressFailure() throws {
    let runs = [try observe("pass"), try observe("reverted"), try observe("pass")]

    let judgement = StressRules.judge(tests, runs: runs)

    #expect(judgement.verdict == .red)
    #expect(
      judgement.findings.map(\.ruleID) == [StressRules.failedRuleID, StressRules.failedRuleID])
    #expect(judgement.findings.first?.message.contains("failed 1 of 3 runs (first: run 2") == true)
  }

  @Test("N passing stress runs are GREEN — catches stress failing stable tests")
  func stressPass() throws {
    let judgement = StressRules.judge(tests, runs: [try observe("pass"), try observe("pass")])

    #expect(judgement.verdict == .green)
    #expect(judgement.findings.isEmpty)
  }

  private func probeGraph() throws -> ModuleGraph {
    try ModuleGraph(packages: [
      PackageManifest(
        describeJSON: Fixture.data("SwiftPM/describe-XUnitProbe.json"),
        repositoryRoot: "\(Fixture.repositoryRoot)/gate/Fixtures/swifttest")
    ])
  }

  @Test(
    "reach targets the module a <Module>Tests target depends on, else its local production dependencies — catches reach measured against the wrong module"
  )
  func reachSubjects() throws {
    #expect(ReachRules.subjects(ofTarget: "ProbeTests", in: try probeGraph()) == ["Probe"])
    #expect(
      ReachRules.subjects(ofTarget: "CounterCoreTests", in: try SampleGraph.graph())
        == ["CounterCore"])
  }

  @Test(
    "a test covering production lines of its target module run alone is GREEN; covering none is RED — catches a test that exercises no production code"
  )
  func reach() throws {
    let graph = try probeGraph()
    let covered = try LineCoverage(
      llvmExport: Fixture.data("SwiftTest/pass-codecov.json"),
      repositoryRoot: "\(Fixture.repositoryRoot)/gate/Fixtures/swifttest")
    let untouched = try LineCoverage(
      llvmExport: Fixture.data("SwiftTest/zero-codecov.json"),
      repositoryRoot: "\(Fixture.repositoryRoot)/gate/Fixtures/swifttest")
    let test = ProbeRun.passSwiftTesting

    let reached = ReachRules.judge(
      test, run: try observe("pass"), coverage: covered, subjects: ["Probe"], graph: graph)
    let unreached = ReachRules.judge(
      test, run: try observe("pass"), coverage: untouched, subjects: ["Probe"], graph: graph)

    #expect(reached.verdict == .green)
    #expect(unreached.verdict == .red)
    #expect(unreached.findings.map(\.ruleID) == [ReachRules.noProductionLinesRuleID])
  }

  @Test(
    "coverage without any file of the target module is BLOCKED, not RED — catches an export from another build read as zero reach"
  )
  func reachForeignExport() throws {
    let judgement = ReachRules.judge(
      ProbeRun.passSwiftTesting, run: try observe("pass"),
      coverage: LineCoverage(files: [:]), subjects: ["Probe"], graph: try probeGraph())

    #expect(judgement.verdict == .blocked)
    #expect(judgement.findings.map(\.ruleID) == [ReachRules.noDataRuleID])
  }

  @Test(
    "a test that fails when run alone is RED fails-alone — catches a test that passes only after another test set up state"
  )
  func reachFailsAlone() throws {
    let judgement = ReachRules.judge(
      ProbeRun.failSwiftTesting, run: try observe("fail", [ProbeRun.failSwiftTesting]),
      coverage: nil, subjects: ["Probe"], graph: try probeGraph())

    #expect(judgement.findings.map(\.ruleID) == [ReachRules.failsAloneRuleID])
  }
}

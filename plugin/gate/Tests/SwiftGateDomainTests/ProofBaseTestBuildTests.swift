import SwiftGateDomain
import Testing

@Suite("a build of new tests at a proof base")
struct ProofBaseTestBuildTests {
  private static let testDirectories = ["Greeter/Tests/GreeterTests"]

  private func error(_ file: String, _ line: Int, _ message: String) throws -> Finding {
    try Finding(
      ruleID: HostTestEvidenceRules.buildFailedRuleID, severity: .major, file: file, line: line,
      message: message, failureScenario: nil)
  }

  @Test(
    "compile errors only in test files name each file once with its first error, in order — catches a test file that doesn't compile read as compiled"
  )
  func testErrorsNameEachFile() throws {
    let run = SelectedTestRun.buildFailed([
      try error("Greeter/Tests/GreeterTests/B.swift", 9, "does not compile: no member 'b'"),
      try error("Greeter/Tests/GreeterTests/A.swift", 4, "does not compile: no member 'a'"),
      try error("Greeter/Tests/GreeterTests/B.swift", 12, "does not compile: no member 'c'"),
    ])

    let outcome = ProofBaseTestBuild.outcome(of: run, testDirectories: Self.testDirectories)

    #expect(
      outcome
        == .testsDontCompile([
          .init(
            file: "Greeter/Tests/GreeterTests/B.swift",
            error: "Greeter/Tests/GreeterTests/B.swift:9: does not compile: no member 'b'"),
          .init(
            file: "Greeter/Tests/GreeterTests/A.swift",
            error: "Greeter/Tests/GreeterTests/A.swift:4: does not compile: no member 'a'"),
        ]))
  }

  @Test(
    "a compile error outside the test directories, or a run with no report, says nothing about the tests — catches a broken reverted tree blamed on the task's tests"
  )
  func errorsOutsideTheTestsAreNoEvidence() throws {
    let outside = SelectedTestRun.buildFailed([
      try error("Greeter/Tests/GreeterTests/A.swift", 4, "does not compile: no member 'a'"),
      try error("Greeter/Sources/Greeter/Greeter.swift", 2, "does not compile: bad"),
    ])

    let broken = ProofBaseTestBuild.outcome(of: outside, testDirectories: Self.testDirectories)
    let silent = ProofBaseTestBuild.outcome(
      of: .noEvidence("swift test wrote no report"), testDirectories: Self.testDirectories)

    guard case .noEvidence(let reason) = broken else {
      Issue.record("expected noEvidence, got \(broken)")
      return
    }
    #expect(reason.contains("Greeter/Sources/Greeter/Greeter.swift:2"), "\(reason)")
    #expect(silent == .noEvidence("swift test wrote no report"))
    #expect(
      ProofBaseTestBuild.outcome(of: .reported([:]), testDirectories: Self.testDirectories)
        == .compiled)
  }

  @Test(
    "each uncompiled test file is 1 test-needs-stub finding naming the file, its error, the proof bases and the fix — catches a test the final gate can only judge compile-only passing check-return"
  )
  func uncompiledFilesAreFindings() {
    let build = ProofBaseTestBuild(
      proofBases: ["aaa111", "bbb222"],
      uncompiled: [
        .init(
          file: "Greeter/Tests/GreeterTests/A.swift",
          error: "Greeter/Tests/GreeterTests/A.swift:4: does not compile: no member 'a'")
      ])
    let taskReturn = TaskReturn(
      task: "greeter", outcome: .designConflict, commits: [], gate: nil, review: nil,
      testsAdded: [], notes: "", designConflict: nil)
    func evidence(_ testBuild: ProofBaseTestBuild?) -> TaskReturnEvidence {
      TaskReturnEvidence(
        branch: "plan/greeter", branchExists: true, commits: [:], gateRun: nil, taskGate: .push,
        taskStatus: nil, taskGateStepsRequired: false, testBuild: testBuild)
    }

    let findings = TaskReturnCheck.findings(taskReturn, evidence: evidence(build))
      .filter { $0.rule == .testNeedsStub }
    let none = TaskReturnCheck.findings(taskReturn, evidence: evidence(nil))
      .filter { $0.rule == .testNeedsStub }

    #expect(findings.count == 1)
    let message = findings.first?.message ?? ""
    #expect(message.hasPrefix("Greeter/Tests/GreeterTests/A.swift doesn't compile"), "\(message)")
    #expect(message.contains("(aaa111, bbb222)"), "\(message)")
    #expect(message.contains("no member 'a'"), "\(message)")
    #expect(message.contains("`surfaceCommit`"), "\(message)")
    #expect(none.isEmpty)
  }
}

import Testing

@testable import SwiftGateDomain

@Suite("Verdict merge")
struct VerdictTests {
  @Test("blocked merged with green stays blocked — catches an unrun tier being reported as passing")
  func blockedNeverDowngradesToGreen() {
    #expect(Verdict.blocked.merged(with: .green) == .blocked)
    #expect(Verdict.green.merged(with: .blocked) == .blocked)
  }

  @Test(
    "red merged with blocked is red — catches a proven code defect hidden behind an env problem")
  func redDominatesBlocked() {
    #expect(Verdict.red.merged(with: .blocked) == .red)
    #expect(Verdict.blocked.merged(with: .red) == .red)
  }

  @Test("red merged with green is red — catches a failing tier masked by a passing one")
  func redDominatesGreen() {
    #expect(Verdict.red.merged(with: .green) == .red)
    #expect(Verdict.green.merged(with: .red) == .red)
  }

  @Test(
    "merging a sequence is order-independent — catches verdicts depending on tier execution order",
    arguments: [
      ([Verdict.green, .blocked, .green], Verdict.blocked),
      ([.blocked, .green, .red], .red),
      ([.red, .blocked], .red),
      ([.green, .green], .green),
    ])
  func sequenceMergeTakesMostSevere(verdicts: [Verdict], expected: Verdict) {
    #expect(Verdict.merged(verdicts) == expected)
    #expect(Verdict.merged(verdicts.reversed()) == expected)
  }

  @Test(
    "merging no verdicts is green — catches a skipped fast tier (doc-only change) failing the gate")
  func emptyMergeIsGreen() {
    #expect(Verdict.merged([]) == .green)
  }

  @Test("verdicts encode as the literal GREEN/RED/BLOCKED strings hooks match on")
  func rawValuesAreTheHookVocabulary() {
    #expect(Verdict.allCases.map(\.rawValue) == ["GREEN", "RED", "BLOCKED"])
  }
}

@Suite("Severity lint mapping")
struct SeverityTests {
  @Test(
    "blocker and major fail the gate as lint errors; minor and nit are warnings — catches a blocker slipping through as a warning",
    arguments: [
      (Severity.blocker, LintLevel.error),
      (.major, .error),
      (.minor, .warning),
      (.nit, .warning),
    ])
  func severityMapsToLintLevel(severity: Severity, level: LintLevel) {
    #expect(severity.lintLevel == level)
    #expect(severity.failsGate == (level == .error))
  }

  @Test(
    "lint levels map back into the gate-failing band — catches a lint error imported as non-failing"
  )
  func lintLevelMapsToSeverity() {
    #expect(Severity(lintLevel: .error).failsGate)
    #expect(!Severity(lintLevel: .warning).failsGate)
  }
}

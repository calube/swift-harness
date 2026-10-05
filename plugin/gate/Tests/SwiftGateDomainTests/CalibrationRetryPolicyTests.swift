import SwiftGateDomain
import Testing

@Suite("calibration retry policy: when a case that missed runs again, and when it passes")
struct CalibrationRetryPolicyTests {
  let policy = CalibrationRetryPolicy.twoOfThree

  @Test(
    "a first attempt that passes decides the case — catches a passing case run again and charged twice"
  )
  func firstPassShortCircuits() {
    #expect(policy.verdict([.pass]) == .passed)
  }

  @Test(
    "a first miss asks for another attempt, a miss then a pass for a third, and a miss followed by two passes passes — catches one ambiguous miss failing the run, or the retry never rescuing a flaky case"
  )
  func missThenTwoPassesPasses() {
    #expect(policy.verdict([]) == .retry)
    #expect(policy.verdict([.miss]) == .retry)
    #expect(policy.verdict([.miss, .pass]) == .retry)
    #expect(policy.verdict([.miss, .pass, .pass]) == .passed)
  }

  @Test(
    "one pass in three, or none, fails — catches an agent that is wrong on the case passing on a lucky retry"
  )
  func oneOrNoPassesFail() {
    #expect(policy.verdict([.miss, .pass, .miss]) == .failed)
    #expect(policy.verdict([.miss, .miss, .pass]) == .failed)
    #expect(policy.verdict([.miss, .miss, .miss]) == .failed)
  }

  @Test(
    "two misses fail at once, since one attempt left can't reach two passes — catches a third paid attempt that can't change the verdict"
  )
  func twoMissesFailEarly() {
    #expect(policy.verdict([.miss, .miss]) == .failed)
  }

  @Test(
    "a single-attempt policy passes on a pass and fails on a miss without retrying — catches the build suite paying for retries it never asked for"
  )
  func singleAttemptNeverRetries() {
    #expect(CalibrationRetryPolicy.singleAttempt.verdict([.pass]) == .passed)
    #expect(CalibrationRetryPolicy.singleAttempt.verdict([.miss]) == .failed)
  }

  @Test(
    "a run passes only when every case passes — catches one failed case hidden by the others passing"
  )
  func runNeedsEveryCase() {
    #expect(policy.runPassed([[.pass], [.miss, .pass, .pass]]))
    #expect(!policy.runPassed([[.pass], [.miss, .pass, .miss]]))
    #expect(!policy.runPassed([[.pass], [.miss]]))
  }
}

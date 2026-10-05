import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// The fifth send-money trial's fixer return, committed but never gated, and the box it came
/// back in.
private enum SendMoney5 {
  static func data(_ name: String) throws -> Data {
    try Fixture.data("BuildReturn/send-money-5/\(name)")
  }

  static func deadlines() throws -> RunTimeBox.Deadlines {
    try #require(try BuildRunJSON.decode(data("run.json")).timeBox).deadlines
  }

  /// The `now` the orchestrator's `run clock` printed right after the return.
  static func now() throws -> Date {
    let text = try Fixture.text("BuildReturn/send-money-5/clock-and-cutoff-at-return.txt")
    let match = try #require(text.firstMatch(of: /"now" : "([^"]+)"/))
    return try Date(String(match.1), strategy: .iso8601)
  }

  /// The fixer's return as JSON: its `gate.runId` is `null`, which the strict decoder refuses.
  static func fixReturn() throws -> [String: Any] {
    try #require(
      try JSONSerialization.jsonObject(with: data("fix-send-flow.json")) as? [String: Any])
  }
}

@Suite("an unconfirmed fix is verified before the cutoff, never halted on time")
struct UnconfirmedFixAdviceTests {
  private func unconfirmed(fix: Bool = true) throws -> Bool {
    let taskReturn = try SendMoney5.fixReturn()
    let outcomeText = try #require(taskReturn["outcome"] as? String)
    let outcome = try #require(TaskReturn.Outcome(rawValue: outcomeText))
    let commits = try #require(taskReturn["commits"] as? [String])
    let gate = try #require(taskReturn["gate"] as? [String: Any])
    let verdictText = try #require(gate["verdict"] as? String)
    let verdict = try #require(Verdict(rawValue: verdictText))
    return TaskHaltAdvice.isUnconfirmedFix(
      fix: fix, outcome: outcome, commits: commits, gateVerdict: verdict)
  }

  private func advise(now: Date, unconfirmedFix: Bool) throws -> TaskHaltAdvice? {
    let deadlines = try SendMoney5.deadlines()
    return TaskHaltAdvice.advise(
      outcome: .gateRed, verdict: .red, rules: [], startedAt: nil, now: now,
      noNewStartsAt: deadlines.noNewStartsAt, cutoffAt: deadlines.cutoffAt,
      unconfirmedFix: unconfirmedFix)
  }

  @Test(
    "the fixer's committed gate-red return with a BLOCKED gate is an unconfirmed fix, and a task worker's is not — catches a never-gated fix read as a red one"
  )
  func capturedReturnIsUnconfirmed() throws {
    #expect(try unconfirmed())
    #expect(try !unconfirmed(fix: false))
    #expect(
      !TaskHaltAdvice.isUnconfirmedFix(
        fix: true, outcome: .gateRed, commits: ["e46da8c"], gateVerdict: .red))
    #expect(
      !TaskHaltAdvice.isUnconfirmedFix(
        fix: true, outcome: .gateRed, commits: [], gateVerdict: nil))
    #expect(
      TaskHaltAdvice.isUnconfirmedFix(
        fix: true, outcome: .gateRed, commits: ["e46da8c"], gateVerdict: nil))
  }

  @Test(
    "checked 215 s before the cutoff, after no new starts, the unconfirmed fix is advised verify, naming the cutoff — catches send-flow blocked by hand with 500 s of box left"
  )
  func unconfirmedFixBeforeTheCutoffVerifies() throws {
    let now = try SendMoney5.now()
    let deadlines = try SendMoney5.deadlines()
    #expect(now >= deadlines.noNewStartsAt && now < deadlines.cutoffAt)

    let advice = try #require(try advise(now: now, unconfirmedFix: unconfirmed()))

    #expect(advice.answer == .verify, "\(advice.why)")
    #expect(advice.why.contains("build cutoff"), "\(advice.why)")
  }

  @Test(
    "the same return at the cutoff, or a red one before it, keeps the old advice — catches verify past the box or for a fix a gate proved red"
  )
  func atTheCutoffOrRedKeepsTheHalt() throws {
    let deadlines = try SendMoney5.deadlines()

    let late = try #require(try advise(now: deadlines.cutoffAt, unconfirmedFix: unconfirmed()))
    let red = try #require(try advise(now: SendMoney5.now(), unconfirmedFix: false))

    #expect(late.answer == .continue, "\(late.why)")
    #expect(red.answer == .continue, "\(red.why)")
  }

  @Test(
    "a budget halt 215 s before the cutoff is refused, naming build cutoff; at the cutoff, with no box, or for gate-red it is not — catches a time halt taken by hand"
  )
  func budgetHaltBeforeTheCutoffIsRefused() throws {
    let now = try SendMoney5.now()
    let cutoffAt = try SendMoney5.deadlines().cutoffAt

    let early = BuildHalts.refusal(reason: .budget, now: now, cutoffAt: cutoffAt)

    #expect(early?.contains("build cutoff") == true, "\(early ?? "nil")")
    #expect(BuildHalts.refusal(reason: .budget, now: cutoffAt, cutoffAt: cutoffAt) == nil)
    #expect(BuildHalts.refusal(reason: .budget, now: now, cutoffAt: nil) == nil)
    #expect(BuildHalts.refusal(reason: .gateRed, now: now, cutoffAt: cutoffAt) == nil)
  }
}

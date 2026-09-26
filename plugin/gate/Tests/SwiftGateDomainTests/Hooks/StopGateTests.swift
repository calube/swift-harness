import SwiftGateDomain
import Testing

@Suite("Stop gate")
struct StopGateTests {
  private let red = "swiftgate RED · lint.date-now at Feed.swift:3"

  @Test(
    "skips when the Swift content is what last passed — catches every stop re-running the fast tier"
  )
  func skipsSinceGreen() {
    let plan = StopGate.plan(
      fingerprint: "abc", lastGreen: "abc", state: StopState(), reentry: false)
    #expect(plan == .skip)
    #expect(
      StopGate.plan(fingerprint: "def", lastGreen: "abc", state: StopState(), reentry: false)
        == .run)
    #expect(
      StopGate.plan(fingerprint: nil, lastGreen: nil, state: StopState(), reentry: false) == .run)
  }

  @Test(
    "unchanged content that was RED reuses the verdict without re-running — catches a 90s re-check when nothing changed"
  )
  func reusesRed() {
    let state = StopState(
      consecutiveBlocks: 1, lastRed: StopState.RedMemo(fingerprint: "f", summary: red))
    #expect(
      StopGate.plan(fingerprint: "f", lastGreen: nil, state: state, reentry: true)
        == .reuseRed(summary: red))
  }

  @Test(
    "RED blocks three consecutive stops, then releases stamped RED — catches an unbounded stop loop and a silent release"
  )
  func threeStrikes() {
    var state = StopState()
    var decisions: [StopDecision] = []
    for attempt in 0..<4 {
      let outcome = StopGate.decide(
        verdict: .red, summary: red, fingerprint: "f", state: state, reentry: attempt > 0)
      decisions.append(outcome.decision)
      state = outcome.state
    }
    for decision in decisions.prefix(3) {
      guard case .block(let reason) = decision else {
        Issue.record("expected a block, got \(decision)")
        continue
      }
      #expect(reason.contains(red))
    }
    guard case .release(let message) = decisions[3] else {
      Issue.record("expected a release, got \(decisions[3])")
      return
    }
    #expect(message.hasPrefix(StopGate.releaseStamp))
    #expect(state.consecutiveBlocks == 0)
  }

  @Test(
    "a fresh stop (no re-entry flag) starts the strike count over — catches strikes leaking from an earlier user turn"
  )
  func freshStopResetsStrikes() {
    let state = StopState(consecutiveBlocks: 3, lastRed: nil)
    let outcome = StopGate.decide(
      verdict: .red, summary: red, fingerprint: "f", state: state, reentry: false)
    guard case .block = outcome.decision else {
      Issue.record("expected a block, got \(outcome.decision)")
      return
    }
    #expect(outcome.state.consecutiveBlocks == 1)
  }

  @Test(
    "BLOCKED neither blocks the stop nor counts as a strike — catches an environment failure trapping the session"
  )
  func blockedIsNotAStrike() {
    let state = StopState(consecutiveBlocks: 2, lastRed: nil)
    let outcome = StopGate.decide(
      verdict: .blocked, summary: "git: not a repository", fingerprint: "f", state: state,
      reentry: true)
    guard case .warn(let message) = outcome.decision else {
      Issue.record("expected a warning, got \(outcome.decision)")
      return
    }
    #expect(message.contains("git: not a repository"))
    #expect(outcome.state.consecutiveBlocks == 2)
    #expect(outcome.lastGreen == nil)
  }

  @Test("GREEN allows the stop, clears strikes and records the content — catches a stale RED memo")
  func greenRecords() {
    let state = StopState(
      consecutiveBlocks: 2, lastRed: StopState.RedMemo(fingerprint: "old", summary: red))
    let outcome = StopGate.decide(
      verdict: .green, summary: "", fingerprint: "new", state: state, reentry: true)
    #expect(outcome.decision == .allow)
    #expect(outcome.state == StopState())
    #expect(outcome.lastGreen == "new")
  }
}

import Foundation
import Testing

struct BoundedWaitTests {
  @Test("waits for the effect to start within a deadline — catches a dismiss sent before the request")
  func deadlineInCondition() async {
    let started = LockIsolated(false)
    let deadline = ContinuousClock.now + .seconds(5)
    while !started.value, ContinuousClock.now < deadline { await Task.yield() }
    #expect(started.value)
  }

  @Test("waits a bounded number of turns — catches a cancellation that never lands")
  func attemptCap() async {
    let cancelled = LockIsolated(false)
    var turns = 0
    while !cancelled.value && turns < 1_000 {
      turns += 1
      await Task.yield()
    }
    #expect(cancelled.value)
  }

  @Test("gives up and records an issue past its deadline — catches a hung effect")
  func breaksPastDeadline() async {
    let done = LockIsolated(false)
    let start = Date()
    while !done.value {
      if Date().timeIntervalSince(start) > 5 {
        Issue.record("timed out")
        break
      }
      await Task.yield()
    }
  }

  @Test("polls with a throwing check — catches a value that never arrives")
  func throwsOut() async throws {
    let ready = LockIsolated(false)
    var remaining = 100
    repeat {
      remaining -= 1
      guard remaining > 0 else { throw CancellationError() }
      try await Task.sleep(for: .milliseconds(1))
    } while !ready.value
  }

  @Test("a loop that only walks a collection awaits nothing — catches the rule flagging iteration")
  func walksWithoutWaiting() async {
    var index = 0
    let values = [1, 2, 3]
    while index < values.count { index += 1 }
    for await value in AsyncStream<Int> { $0.finish() } { #expect(value > 0) }
    #expect(index == 3)
  }
}

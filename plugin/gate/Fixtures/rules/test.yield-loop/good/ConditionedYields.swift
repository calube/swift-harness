import Testing

struct ConditionedYieldTests {
  @Test("yields once to let a started task run — catches the rule flagging a single turn")
  func singleYield() async {
    let started = LockIsolated(false)
    let task = Task { started.setValue(true) }
    await Task.yield()
    await task.value
    #expect(started.value)
  }

  @Test("polls a flag with an attempt cap and leaves when it flips — catches an effect that never starts")
  func pollsACondition() async {
    let started = LockIsolated(false)
    let task = Task { started.setValue(true) }
    for _ in 0..<1_000 {
      if started.value { break }
      await Task.yield()
    }
    await task.value
    #expect(started.value)
  }

  @Test("waits on a flag with a deadline — catches a cancellation that never lands")
  func deadlineInCondition() async {
    let cancelled = LockIsolated(false)
    let deadline = ContinuousClock.now + .seconds(5)
    while !cancelled.value, ContinuousClock.now < deadline { await Task.yield() }
    #expect(cancelled.value)
  }

  @Test("yields between the items it hands over — catches the rule flagging per-item interleaving")
  func yieldsPerItem() async {
    let received = LockIsolated<[Int]>([])
    for item in [1, 2, 3] {
      received.withValue { $0.append(item) }
      await Task.yield()
    }
    #expect(received.value == [1, 2, 3])
  }

  @Test("each child task yields inside its own closure — catches the rule reading a closure as the loop's wait")
  func yieldsInChildTasks() async {
    let count = LockIsolated(0)
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<3 {
        group.addTask {
          await Task.yield()
          count.withValue { $0 += 1 }
        }
      }
    }
    #expect(count.value == 3)
  }

  @Test("a counted loop that awaits the store, not the scheduler — catches the rule flagging every awaiting loop")
  @MainActor
  func countedReceives() async {
    let clock = TestClock()
    let store = TestStore(initialState: Ticker.State()) {
      Ticker()
    } withDependencies: {
      $0.continuousClock = clock
    }
    await store.send(.startTapped) { $0.isRunning = true }
    await clock.advance(by: .seconds(3))
    for elapsed in 1...3 {
      await store.receive(\.tick) { $0.elapsed = elapsed }
    }
    await store.send(.stopTapped) { $0.isRunning = false }
  }
}

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// Samples an operation several times so a latency budget assertion survives machine load. A
/// busy scheduler can only ever add wait time to a measurement, never remove it, so the fastest
/// of several samples is the noise-resistant read of the code's own cost: a genuine regression
/// slows every sample, including the fastest, while a scheduler stall only ever slows some of
/// them.
///
/// Pair this with ``threadCPUMilliseconds(_:)`` rather than a wall-clock timer: a hook budget is
/// a cost budget, and wall time also counts time this process spent off the CPU waiting for a
/// busy machine to schedule it, which the fastest-of-N trick alone can't fully absorb once other
/// processes hold the CPU for the whole sampling window (as sub-project 2's evals found: 131 to
/// 1149 ms wall on a loaded machine, for hooks whose own cost never changed).
///
/// Neither of the shared readings here is process-wide: `RUSAGE_SELF`/`RUSAGE_CHILDREN` looked
/// right at first but measure the whole `xctest` binary, so every other test's threads and every
/// other test's reaped children count against whichever hook happens to be sampled at the same
/// moment — exactly the kind of load-dependent noise this file exists to remove. A per-thread
/// clock and a per-child `wait4` reading don't have that problem: each is scoped to the one thing
/// being measured, no matter what else the process is doing at the same time.
public enum Latency {
  /// Runs `sample` `times` times (default 5) and returns every measured duration in
  /// milliseconds, in run order. Callers assert `samples.min()! < budget` and report every
  /// sample alongside the budget on failure.
  public static func samples(
    times: Int = 5, _ sample: () async throws -> Int
  ) async rethrows -> [Int] {
    precondition(times > 0, "Latency.samples needs at least one sample")
    var samples: [Int] = []
    samples.reserveCapacity(times)
    for _ in 0..<times {
      samples.append(try await sample())
    }
    return samples
  }

  /// Runs `body` and returns its result together with the CPU time it used, in milliseconds.
  ///
  /// `body` runs with a task executor preference for a thread of its own that runs nothing else,
  /// and that thread's `CLOCK_THREAD_CPUTIME_ID` is read on it before and after. A clock read on
  /// the calling thread is wrong once `body` suspends: the task can resume on another
  /// cooperative thread, or on the same one after it ran other tests' work, and the difference
  /// then counts that other work. Under the full parallel suite such readings ranged from
  /// -2 971 to +4 720 ms for a hook that costs about 3 ms.
  ///
  /// Work `body` hands to another executor (the main actor, an actor with its own executor, a
  /// detached task) is not counted. Once a hook shells out to a real child process, measure that
  /// child's own `wait4` rusage instead (see `MeasuredProcessRunner`).
  public static func threadCPUMilliseconds<T, Failure: Error>(
    _ body: () async throws(Failure) -> T
  ) async throws(Failure) -> (T, Int) {
    let executor = DedicatedThreadExecutor()
    defer { executor.stop() }
    let before = await executor.threadCPUNanoseconds()
    let value = try await withTaskExecutorPreference(executor, operation: body)
    let after = await executor.threadCPUNanoseconds()
    return (value, Int((after - before) / 1_000_000))
  }
}

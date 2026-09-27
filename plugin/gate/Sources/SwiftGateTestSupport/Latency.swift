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
/// Pair this with ``cpuMilliseconds(_:)`` rather than a wall-clock timer: a hook budget is a cost
/// budget, and wall time also counts time this process spent off the CPU waiting for a busy
/// machine to schedule it, which the fastest-of-N trick alone can't fully absorb once other
/// processes hold the CPU for the whole sampling window (as sub-project 2's evals found: 131 to
/// 1149 ms wall on a loaded machine, for hooks whose own cost never changed).
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

  /// Runs `body` and returns its result together with the CPU time actually consumed while it
  /// ran, in milliseconds: this process's own time (`RUSAGE_SELF`) plus every child process it
  /// spawned and reaped meanwhile (`RUSAGE_CHILDREN`). A child's rusage is credited to its parent
  /// as soon as the parent reaps it — which `LiveProcessRunner` (and `Foundation.Process`) does
  /// before `run(_:)` returns — so a hook that shells out to `git` has that git call's cost
  /// counted here too. Unlike a wall-clock reading, this is unaffected by another process on the
  /// machine holding the CPU: a contended scheduler only delays when this code runs, never how
  /// much of it the CPU actually executed.
  public static func cpuMilliseconds<T>(
    _ body: () async throws -> T
  ) async rethrows -> (T, Int) {
    let before = ProcessCPUTime.current()
    let value = try await body()
    let after = ProcessCPUTime.current()
    return (value, after.milliseconds(since: before))
  }
}

/// This process's own CPU time plus every child process's, as of the moment it was read. See
/// ``Latency/cpuMilliseconds(_:)``.
struct ProcessCPUTime {
  private let microseconds: Int64

  static func current() -> ProcessCPUTime {
    var own = rusage()
    getrusage(RUSAGE_SELF, &own)
    var children = rusage()
    getrusage(RUSAGE_CHILDREN, &children)
    let total =
      Self.microseconds(own.ru_utime) + Self.microseconds(own.ru_stime)
      + Self.microseconds(children.ru_utime) + Self.microseconds(children.ru_stime)
    return ProcessCPUTime(microseconds: total)
  }

  func milliseconds(since earlier: ProcessCPUTime) -> Int {
    Int((microseconds - earlier.microseconds) / 1000)
  }

  private static func microseconds(_ time: timeval) -> Int64 {
    Int64(time.tv_sec) * 1_000_000 + Int64(time.tv_usec)
  }
}

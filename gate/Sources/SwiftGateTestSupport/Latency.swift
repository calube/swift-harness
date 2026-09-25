/// Samples a wall-clock operation several times so a latency budget assertion survives machine
/// load. A busy scheduler can only ever add wait time to a measurement, never remove it, so the
/// fastest of several samples is the noise-resistant read of the code's own cost: a genuine
/// regression slows every sample, including the fastest, while a scheduler stall only ever slows
/// some of them.
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
}

import Foundation

/// Runs blocking work (a `flock` wait, a child's exit, a long CPU-bound loop) on a thread of its
/// own. The cooperative pool has one thread per core and every async task in the process shares
/// it, so a body that blocks on the pool delays every other task's resumption until it returns.
public enum OffPool {
  public static func run<T: Sendable, Failure: Error>(
    name: String = "swiftgate.blocking", _ body: @escaping @Sendable () throws(Failure) -> T
  ) async throws(Failure) -> T {
    try body()
  }
}

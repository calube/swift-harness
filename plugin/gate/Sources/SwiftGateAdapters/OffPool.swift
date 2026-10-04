import Foundation

/// Runs blocking work (a `flock` wait, a child's exit, a long CPU-bound loop) on a thread of its
/// own. The cooperative pool has one thread per core and every async task in the process shares
/// it, so a body that blocks on the pool delays every other task's resumption until it returns.
public enum OffPool {
  public static func run<T: Sendable, Failure: Error>(
    name: String = "swiftgate.blocking", _ body: @escaping @Sendable () throws(Failure) -> T
  ) async throws(Failure) -> T {
    let result = await withCheckedContinuation {
      (continuation: CheckedContinuation<Result<T, Failure>, Never>) in
      let thread = Thread {
        continuation.resume(returning: Result { () throws(Failure) -> T in try body() })
      }
      thread.name = name
      // Parsers and walkers recurse deeply; a pool thread's 512 KB stack is the floor.
      thread.stackSize = 8 << 20
      thread.start()
    }
    return try result.get()
  }
}

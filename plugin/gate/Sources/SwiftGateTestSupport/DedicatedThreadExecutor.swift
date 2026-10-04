import Dispatch
import Foundation
import Synchronization

/// A task executor backed by one thread that runs only the jobs and closures handed to it, so
/// that thread's CPU clock is exactly the CPU they used. Work on the shared cooperative pool can
/// resume on any of its threads, and each of those threads also runs other tests' work in
/// between.
///
/// ``stop()`` ends the thread once the work already queued has run. Work enqueued after that,
/// such as an unstructured task that inherited this executor, runs on the shared pool instead.
public final class DedicatedThreadExecutor: TaskExecutor {
  private enum Work: Sendable {
    case job(UnownedJob)
    case closure(@Sendable () -> Void)
  }

  private let queue = Mutex<(work: [Work], stopped: Bool)>(([], false))
  /// Signalled once per queued item, and once more by ``stop()``.
  private let ready = DispatchSemaphore(value: 0)

  public init() {
    let thread = Thread { [self] in drain() }
    thread.name = "swiftgate.dedicated-executor"
    thread.start()
  }

  public func enqueue(_ job: consuming ExecutorJob) {
    let unowned = UnownedJob(job)
    if !accept(.job(unowned)) { globalConcurrentExecutor.enqueue(ExecutorJob(unowned)) }
  }

  /// Runs `work` on this executor's thread after the work already queued.
  public func run(_ work: @escaping @Sendable () -> Void) {
    if !accept(.closure(work)) { DispatchQueue.global().async(execute: work) }
  }

  /// The CPU time this executor's thread has used so far, read on that thread.
  public func threadCPUNanoseconds() async -> UInt64 {
    await withCheckedContinuation { continuation in
      run { continuation.resume(returning: clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) }
    }
  }

  public func stop() {
    queue.withLock { $0.stopped = true }
    ready.signal()
  }

  private func accept(_ work: Work) -> Bool {
    let accepted = queue.withLock { state in
      guard !state.stopped else { return false }
      state.work.append(work)
      return true
    }
    if accepted { ready.signal() }
    return accepted
  }

  private func drain() {
    while true {
      ready.wait()
      let next = queue.withLock { $0.work.isEmpty ? nil : $0.work.removeFirst() }
      switch next {
      case .job(let job): job.runSynchronously(on: asUnownedTaskExecutor())
      case .closure(let work): work()
      case nil: return
      }
    }
  }
}

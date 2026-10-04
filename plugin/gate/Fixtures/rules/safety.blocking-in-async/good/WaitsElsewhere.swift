import Foundation

struct Exporter {
  func exportNow(_ process: Process, lock fd: Int32) {
    process.waitUntilExit()
    flock(fd, LOCK_EX)
  }

  func export(_ process: Process, lock fd: Int32, semaphore: DispatchSemaphore) async {
    Thread {
      process.waitUntilExit()
      semaphore.signal()
    }.start()
    DispatchQueue.global().async { flock(fd, LOCK_EX) }
    _ = flock(fd, LOCK_EX | LOCK_NB)
    var status: Int32 = 0
    _ = waitpid(process.processIdentifier, &status, WNOHANG)
    try? await Task.sleep(for: .milliseconds(10))
    usleep(100)  // swiftgate:allow safety.blocking-in-async — a 0.1 ms backoff in a spin loop
  }

  func wait(on queue: AsyncQueue) async {
    await queue.wait()
  }
}

actor AsyncQueue {
  func wait() async {}
}

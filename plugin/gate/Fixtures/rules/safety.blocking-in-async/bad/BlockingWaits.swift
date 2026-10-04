import Foundation

struct Exporter {
  func export(_ process: Process, lock fd: Int32, semaphore: DispatchSemaphore) async {
    process.waitUntilExit()
    semaphore.wait()
    _ = DispatchGroup().wait(timeout: .now() + 5)
    Thread.sleep(forTimeInterval: 0.1)
    usleep(1_000)
    flock(fd, LOCK_EX)
    var status: Int32 = 0
    waitpid(process.processIdentifier, &status, 0)
    _ = FileHandle.standardInput.readDataToEndOfFile()
  }

  func start(_ semaphore: DispatchSemaphore) {
    Task { semaphore.wait() }
  }
}

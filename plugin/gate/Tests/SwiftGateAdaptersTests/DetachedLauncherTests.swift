import Darwin
import Foundation
import SwiftGateAdapters
import SwiftGateTestSupport
import Testing

@Suite("DetachedLauncher")
struct DetachedLauncherTests {
  let directory = TestTemporaryDirectory.root.appending(
    path: "detached-\(UUID().uuidString)", directoryHint: .isDirectory)

  /// Reaps a child this test started, so its PID can't be reused while the test still names it.
  /// The wait blocks until the child exits, so it runs on a thread of its own.
  static func reap(_ pid: Int32) async -> Int32 {
    await OffPool.run {
      var status: Int32 = 0
      while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
      return status
    }
  }

  @Test(
    "a detached process runs in the given directory with stdin empty and stdout and stderr appended to the log — catches a holder whose output is lost or that blocks on the caller's terminal"
  )
  func outputAndDirectory() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let log = directory.appending(path: "agent-device.log")
    try Data("earlier\n".utf8).write(to: log)

    let pid = try DetachedLauncher().launch(
      DetachedLaunch(
        executable: "/bin/sh",
        arguments: ["-c", "pwd -P; echo to-stderr >&2; read line; echo \"stdin:$line\""],
        workingDirectory: directory.path, logPath: log.path))
    _ = await Self.reap(pid)

    let text = try String(contentsOf: log, encoding: .utf8)
    #expect(text == "earlier\n\(CanonicalPath.of(directory))\nto-stderr\nstdin:\n")
  }

  @Test(
    "a detached process leads a session of its own — catches a holder killed along with the tool call that started it"
  )
  func ownSession() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let pid = try DetachedLauncher().launch(
      DetachedLaunch(
        executable: "/bin/sleep", arguments: ["30"], workingDirectory: directory.path,
        logPath: directory.appending(path: "log").path))

    #expect(getsid(pid) == pid)
    #expect(getsid(pid) != getsid(0))
    kill(pid, SIGKILL)
    _ = await Self.reap(pid)
  }

  @Test(
    "a missing executable is an error naming it, never a PID — catches sim up waiting on a holder that never started"
  )
  func missingExecutable() throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let missing = directory.appending(path: "no-such-tool").path

    #expect(throws: DetachedLaunchError.spawn(executable: missing, errno: ENOENT)) {
      try DetachedLauncher().launch(
        DetachedLaunch(
          executable: missing, arguments: [], workingDirectory: directory.path,
          logPath: directory.appending(path: "log").path))
    }
  }

  @Test(
    "a process launched from a thread that blocks SIGTERM still ends on SIGTERM — catches a detached server, started from a concurrency thread, that no kill but SIGKILL stops"
  )
  func endsOnSigtermFromABlockingThread() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let log = directory.appending(path: "log").path
    let workingDirectory = directory.path
    let pid = try await OffPool.run { () throws -> Int32 in
      var blocked = sigset_t()
      sigemptyset(&blocked)
      sigaddset(&blocked, SIGTERM)
      var before = sigset_t()
      pthread_sigmask(SIG_BLOCK, &blocked, &before)
      defer { pthread_sigmask(SIG_SETMASK, &before, nil) }
      return try DetachedLauncher().launch(
        DetachedLaunch(
          executable: "/bin/sleep", arguments: ["30"], workingDirectory: workingDirectory,
          logPath: log))
    }
    kill(pid, SIGTERM)
    let status = await Self.reap(pid)
    #expect(status & 0x7f == SIGTERM, "exit status \(status)")
  }
}

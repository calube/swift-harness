import Darwin
import Foundation
import SwiftGateAdapters
import SwiftGateTestSupport
import Testing

/// The built `swiftgate`, killed while a child it started through ``LiveProcessRunner`` is still
/// running.
@Suite("a killed swiftgate")
struct KilledRunChildrenTests {
  /// The child's own sleep; a child gone in under half of it was killed, not left to finish. Short
  /// enough that an orphan still ends the test, long enough to dwarf any scheduling delay.
  private static let childLifetime = 120

  static func onPath(_ name: String) -> Bool {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    return path.split(separator: ":").contains {
      FileManager.default.isExecutableFile(atPath: "\($0)/\(name)")
    }
  }

  @Test(
    "a terminated swiftgate takes the tools it started down with it — catches builds orphaned by a killed run piling up and wedging the machine",
    arguments: [SIGTERM, SIGINT, SIGHUP])
  func terminatedRunKillsChildren(signal: Int32) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "swiftgate-killed-run-\(UUID().uuidString)", directoryHint: .isDirectory)
    let bin = directory.appending(path: "bin", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let ready = directory.appending(path: "ready").path
    try #require(mkfifo(ready, 0o600) == 0)
    // Stands in for any tool swiftgate runs: it reports who it is, then holds the pipe open for
    // as long as it lives.
    let git = bin.appending(path: "git")
    try Data(
      """
      #!/bin/sh
      exec 3>"$READY"
      echo "$PPID $$" >&3
      exec sleep \(Self.childLifetime)

      """.utf8
    ).write(to: git)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: git.path)

    let binary = Fixture.gateDirectory.appending(path: ".build/debug/swiftgate").path
    let start = ContinuousClock.now
    let run = Task {
      try await LiveProcessRunner().run(
        ProcessInvocation(
          executable: binary, arguments: ["comments", "--staged"],
          environmentOverlay: [
            "PATH": "\(bin.path):/usr/bin:/bin", "READY": ready,
            "LLVM_PROFILE_FILE": directory.appending(path: "swiftgate-%p.profraw").path,
          ],
          workingDirectory: directory.path, timeout: .seconds(3600)))
    }
    var lines = Self.lines(of: ready).makeAsyncIterator()
    let pids = try #require(await lines.next()).split(separator: " ").compactMap { pid_t($0) }
    try #require(pids.count == 2)
    let (swiftgate, child) = (pids[0], pids[1])
    defer { kill(child, SIGKILL) }

    kill(swiftgate, signal)
    let output = try await run.value
    #expect(output.status == .signaled(signal))
    // The pipe reaches end-of-file only once its last holder, the child, has exited.
    #expect(await lines.next() == nil)
    #expect(ContinuousClock.now - start < .seconds(Self.childLifetime / 2))
  }

  @Test(
    "a terminated swiftgate takes down a grandchild that put itself in its own process group — catches swiftpm-testing-helper-style orphans a plain kill(-pid) of the direct child's group can't reach",
    .enabled(if: onPath("python3"), "python3 is not on PATH")
  )
  func terminatedRunKillsARegroupedGrandchild() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "swiftgate-killed-run-\(UUID().uuidString)", directoryHint: .isDirectory)
    let bin = directory.appending(path: "bin", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let ready = directory.appending(path: "ready").path
    try #require(mkfifo(ready, 0o600) == 0)
    // Stands in for `swift test`, which runs its own test-runner helper as a grandchild that puts
    // itself in a fresh process group — `os.setpgid` on the direct child here would fail (EPERM):
    // a process already leading its own group, as swiftgate's spawned child is, can't do it again.
    let git = bin.appending(path: "git")
    try Data(
      """
      #!/bin/sh
      exec python3 - "$READY" <<'PY'
      import os, sys, time
      ready = sys.argv[1]
      swiftgate_pid = os.getppid()
      git_pid = os.getpid()
      child = os.fork()
      if child == 0:
          os.setpgid(0, 0)
          # Held open for the sleep, like the shell script's `exec 3>`: closing right after the
          # write (as `with open(...)` would) reaches end-of-file whether or not this process is
          # still alive, so the read side could never tell a killed grandchild from a live one.
          fd = os.open(ready, os.O_WRONLY)
          os.write(fd, ("%d %d %d\\n" % (swiftgate_pid, git_pid, os.getpid())).encode())
          time.sleep(\(Self.childLifetime))
          os.close(fd)
          os._exit(0)
      else:
          os.waitpid(child, 0)
      PY

      """.utf8
    ).write(to: git)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: git.path)

    let binary = Fixture.gateDirectory.appending(path: ".build/debug/swiftgate").path
    let start = ContinuousClock.now
    let run = Task {
      try await LiveProcessRunner().run(
        ProcessInvocation(
          executable: binary, arguments: ["comments", "--staged"],
          environmentOverlay: [
            "PATH": "\(bin.path):/usr/bin:/bin", "READY": ready,
            "LLVM_PROFILE_FILE": directory.appending(path: "swiftgate-%p.profraw").path,
          ],
          workingDirectory: directory.path, timeout: .seconds(3600)))
    }
    var lines = Self.lines(of: ready).makeAsyncIterator()
    let pids = try #require(await lines.next()).split(separator: " ").compactMap { pid_t($0) }
    try #require(pids.count == 3)
    let (swiftgate, _, grandchild) = (pids[0], pids[1], pids[2])
    #expect(getpgid(grandchild) == grandchild, "the grandchild should lead its own process group")
    defer { kill(grandchild, SIGKILL) }

    kill(swiftgate, SIGTERM)
    let output = try await run.value
    #expect(output.status == .signaled(SIGTERM))
    // The pipe reaches end-of-file only once its last holder, the grandchild, has exited.
    #expect(await lines.next() == nil)
    #expect(ContinuousClock.now - start < .seconds(Self.childLifetime / 2))
  }

  @Test(
    "a terminated swiftgate kills a child that ignores SIGTERM once the grace period passes — catches a test runner that shrugs off the forwarded SIGTERM outliving the gate a Bash timeout stopped",
    arguments: [SIGTERM, SIGINT])
  func terminatedRunKillsAChildIgnoringSIGTERM(signal: Int32) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "swiftgate-killed-run-\(UUID().uuidString)", directoryHint: .isDirectory)
    let bin = directory.appending(path: "bin", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let ready = directory.appending(path: "ready").path
    try #require(mkfifo(ready, 0o600) == 0)
    // An ignored signal stays ignored across `exec`, so the sleep that holds the pipe shrugs off
    // every SIGTERM, as a runner that handles it and keeps going would.
    let git = bin.appending(path: "git")
    try Data(
      """
      #!/bin/sh
      trap '' TERM
      exec 3>"$READY"
      echo "$PPID $$" >&3
      exec sleep \(Self.childLifetime)

      """.utf8
    ).write(to: git)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: git.path)

    let binary = Fixture.gateDirectory.appending(path: ".build/debug/swiftgate").path
    let start = ContinuousClock.now
    let run = Task {
      try await LiveProcessRunner().run(
        ProcessInvocation(
          executable: binary, arguments: ["comments", "--staged"],
          environmentOverlay: [
            "PATH": "\(bin.path):/usr/bin:/bin", "READY": ready,
            "LLVM_PROFILE_FILE": directory.appending(path: "swiftgate-%p.profraw").path,
          ],
          workingDirectory: directory.path, timeout: .seconds(3600)))
    }
    var lines = Self.lines(of: ready).makeAsyncIterator()
    let pids = try #require(await lines.next()).split(separator: " ").compactMap { pid_t($0) }
    try #require(pids.count == 2)
    let (swiftgate, child) = (pids[0], pids[1])
    defer { kill(child, SIGKILL) }

    kill(swiftgate, signal)
    let output = try await run.value
    #expect(output.status == .signaled(signal))
    // The pipe reaches end-of-file only once its last holder, the child, has exited.
    #expect(await lines.next() == nil)
    #expect(ContinuousClock.now - start < .seconds(Self.childLifetime / 2))
  }

  /// The lines written to the named pipe at `path`, finishing once every writer has closed it:
  /// for a child that holds it open for life, once the child is gone. Reads on a dedicated
  /// thread, since opening the pipe blocks until a writer opens it.
  private static func lines(of path: String) -> AsyncStream<String> {
    AsyncStream { continuation in
      Thread {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else {
          continuation.finish()
          return
        }
        defer { close(fd) }
        var pending: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 256)
        while true {
          let count = read(fd, &buffer, buffer.count)
          if count < 0, errno == EINTR { continue }
          if count <= 0 { break }
          pending += buffer[0..<count]
          while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            continuation.yield(String(decoding: pending[..<newline], as: UTF8.self))
            pending.removeSubrange(...newline)
          }
        }
        continuation.finish()
      }.start()
    }
  }
}

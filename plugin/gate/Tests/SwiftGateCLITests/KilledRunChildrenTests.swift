import Darwin
import Foundation
import SwiftGateAdapters
import SwiftGateTestSupport
import Testing

/// The built `swiftgate`, killed while a child it started is still running.
@Suite("a killed swiftgate")
struct KilledRunChildrenTests {
  /// The child's own sleep; a child gone in under half of it was killed, not left to finish.
  private static let childLifetime = 600

  @Test(
    "a terminated swiftgate takes the tools it started down with it — catches builds orphaned by a killed run piling up and wedging the machine",
    arguments: [SIGTERM, SIGINT, SIGHUP])
  func terminatedRunKillsChildren(signal: Int32) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "swiftgate-killed-run-\(UUID().uuidString)", directoryHint: .isDirectory)
    let bin = directory.appending(path: "bin", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let ready = try ReadinessFIFO()
    defer { ready.remove() }
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
            "PATH": "\(bin.path):/usr/bin:/bin", "READY": ready.path,
            "LLVM_PROFILE_FILE": directory.appending(path: "swiftgate-%p.profraw").path,
          ],
          workingDirectory: directory.path, timeout: .seconds(3600)))
    }
    var lines = ready.lines().makeAsyncIterator()
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
}

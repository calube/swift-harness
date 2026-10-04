import Darwin
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import Testing

@Suite("LiveAreaCommandRunner")
struct LiveAreaCommandRunnerTests {
  let runner = LiveAreaCommandRunner(
    processRunner: LiveProcessRunner(
      baseEnvironment: ["PATH": "/usr/bin:/bin"], terminationGracePeriod: .milliseconds(200),
      postExitDrainLimit: .milliseconds(200)))

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "area-runner-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    // `$PWD` in the child is the real path, `/private/var/…`, which `URL` would shorten.
    let real = try #require(realpath(url.path, nil))
    defer { free(real) }
    return URL(filePath: String(cString: real), directoryHint: .isDirectory)
  }

  private func request(
    _ command: String, in directory: URL, deadline: Duration = .seconds(20),
    environment: [String: String] = [:], junitPath: String? = nil
  ) -> AreaCommandRequest {
    AreaCommandRequest(
      area: "api", step: .testFiles, command: command, workingDirectory: directory.path,
      deadline: deadline, environment: environment, junitPath: junitPath)
  }

  @Test(
    "a command that sleeps past its deadline ends timed out and leaves no child — catches an orphaned process group"
  )
  func timeoutKillsTheGroup() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let pidFile = directory.appending(path: "pid")
    let outcome = await runner.run(
      request(
        "echo started; sleep 60 & echo $! > '\(pidFile.path)'; wait", in: directory,
        deadline: .seconds(2)))
    #expect(outcome == .timedOut(tail: "started"))
    let pid = try #require(
      pid_t(
        try String(contentsOf: pidFile, encoding: .utf8)
          .trimmingCharacters(in: .whitespacesAndNewlines)))
    #expect(!isRunning(pid), "the backgrounded sleep outlived the timeout")
  }

  /// `kill -0` succeeds on a zombie too, and a killed orphan stays one until launchd reaps it.
  private func isRunning(_ pid: pid_t) -> Bool {
    guard kill(pid, 0) == 0 else { return false }
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
    return info.kp_proc.p_stat != SZOMB
  }

  @Test("a command killed by a signal is crashed — catches a signal read as a plain failure")
  func signalIsCrash() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let outcome = await runner.run(request("echo before; kill -ABRT $$", in: directory))
    #expect(outcome == .crashed(signal: SIGABRT, tail: "before"))
  }

  @Test(
    "the tail interleaves stderr in order and runs in the area root with its environment — catches stderr dropped or the wrong directory"
  )
  func tailAndEnvironment() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let outcome = await runner.run(
      request(
        "echo one; echo two >&2; printf '%s|%s\\n' \"$PWD\" \"$AREA_CACHE\"; exit 3",
        in: directory, environment: ["AREA_CACHE": "/shared/npm"]))
    #expect(
      outcome == .failed(exit: 3, tail: "one\ntwo\n\(directory.path)|/shared/npm", junit: nil))
  }

  @Test(
    "an expanded path holding a space and a quote reaches the command as 1 argument — catches unquoted expansion"
  )
  func expandedPathIsOneArgument() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let expanded = AreaCommandExpansion.expand(
      "printf '<%s>\\n' {files}; exit 1", files: ["it's a file.txt"], tests: [], junitPath: "")
    let outcome = await runner.run(request(expanded.command, in: directory))
    #expect(outcome == .failed(exit: 1, tail: "<it's a file.txt>", junit: nil))
  }

  @Test("the JUnit report the command writes is read — catches the report ignored")
  func readsJUnit() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let junit = directory.appending(path: "report.xml").path
    let outcome = await runner.run(
      request("printf '<testsuites/>' > '\(junit)'; exit 1", in: directory, junitPath: junit))
    #expect(outcome == .failed(exit: 1, tail: "", junit: Data("<testsuites/>".utf8)))
  }

  @Test("a report left by an earlier run is not read — catches a stale report taken as this run's")
  func staleJUnitIgnored() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let junit = directory.appending(path: "report.xml")
    try Data("<testsuites/>".utf8).write(to: junit)
    let outcome = await runner.run(request("exit 1", in: directory, junitPath: junit.path))
    #expect(outcome == .failed(exit: 1, tail: "", junit: nil))
  }

  @Test("a passing command is passed — catches exit 0 read as a failure")
  func passes() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(await runner.run(request("echo ok", in: directory)) == .passed)
  }
}

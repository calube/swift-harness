import Darwin
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

@Suite("LiveAreaCommandRunner")
struct LiveAreaCommandRunnerTests {
  let runner = LiveAreaCommandRunner(
    processRunner: LiveProcessRunner(
      baseEnvironment: ["PATH": "/usr/bin:/bin"], terminationGracePeriod: .milliseconds(200),
      postExitDrainLimit: .milliseconds(200)))

  private func temporaryDirectory() throws -> URL {
    let url = TestTemporaryDirectory.root
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

  /// `/bin/sh` that writes a 1-case report failing `<classname>.<name>` to `path`.
  private func writing(_ path: String, failing classname: String, _ name: String) -> String {
    "printf '<testsuite><testcase classname=\"\(classname)\" name=\"\(name)\"><failure/></testcase></testsuite>' > '\(path)'"
  }

  @Test(
    "a {junit} the command made a directory of reports reads every report in it — catches a Gradle or Maven module's report left unread"
  )
  func readsReportDirectory() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let junit = directory.appending(path: "junit/api.test.xml").path
    let command =
      "mkdir -p '\(junit)' && \(writing("\(junit)/TEST-a.xml", failing: "a", "x"))"
      + " && \(writing("\(junit)/TEST-b.xml", failing: "b", "y")); exit 1"
    let outcome = await runner.run(request(command, in: directory, junitPath: junit))
    #expect(BaselineStepResult.of(outcome) == .failedTests(["a.x", "b.y"]))
  }

  @Test(
    "Swift Testing's report beside the named one is read, and 1 an earlier run left is not — catches a Swift Testing failure absorbed with the XCTest base, or a stale one read as this run's"
  )
  func readsCompanionReport() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let junit = directory.appending(path: "core.test.xml").path
    let companion = directory.appending(path: "core.test-swift-testing.xml").path
    let both = await runner.run(
      request(
        "\(writing(junit, failing: "Tests.Alpha", "testFlaky")) && \(writing(companion, failing: "Tests", "fresh()")); exit 1",
        in: directory, junitPath: junit))
    #expect(
      BaselineStepResult.of(both) == .failedTests(["Tests.Alpha.testFlaky", "Tests.fresh()"]))

    let xctestOnly = await runner.run(
      request(
        "\(writing(junit, failing: "Tests.Alpha", "testFlaky")); exit 1", in: directory,
        junitPath: junit))
    #expect(BaselineStepResult.of(xctestOnly) == .failedTests(["Tests.Alpha.testFlaky"]))
  }

  @Test(
    "the directory {junit} names is made before the run — catches a runner that writes no report into a missing directory"
  )
  func makesTheReportDirectory() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let junit = directory.appending(path: "junit/core.test.xml").path
    let outcome = await runner.run(
      request(
        "[ -d '\(directory.path)/junit' ] && \(writing(junit, failing: "a", "x")); exit 1",
        in: directory, junitPath: junit))
    #expect(BaselineStepResult.of(outcome) == .failedTests(["a.x"]))
  }

  @Test(
    "2 builds into 1 worktree's DerivedData run 1 at a time, and builds into 2 DerivedData run together — catches a gate's xcodebuild starting in a slot while the warm-up still builds there, which xcodebuild fails on its locked build database"
  )
  func oneBuildPerDerivedData() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let active = Mutex((now: 0, most: 0))
    // Each command waits, yielding, for a second one to arrive, so 2 that may overlap do.
    let processes = FakeProcessRunner { _ async throws(ProcessRunnerError) -> ProcessOutput in
      active.withLock {
        $0.now += 1
        $0.most = max($0.most, $0.now)
      }
      let deadline = ContinuousClock.now + .seconds(1)
      while active.withLock({ $0.now }) < 2, ContinuousClock.now < deadline { await Task.yield() }
      active.withLock { $0.now -= 1 }
      return ProcessOutput(status: .exited(0), stdout: "", stderr: "")
    }
    let runner = LiveAreaCommandRunner(processRunner: processes)
    func build(into derivedData: String) -> AreaCommandRequest {
      AreaCommandRequest(
        area: "app", step: .build, command: "xcodebuild build", workingDirectory: directory.path,
        deadline: .seconds(20), environment: [:], junitPath: nil,
        derivedDataSeed: DerivedDataSeedCopy(
          seed: directory.appending(path: "seed").path,
          destination: directory.appending(path: derivedData).path))
    }

    async let first = runner.run(build(into: "slot/areas/app"))
    async let second = runner.run(build(into: "slot/areas/app"))
    #expect(await [first, second] == [.passed, .passed])
    #expect(active.withLock { $0.most } == 1)

    active.withLock { $0 = (0, 0) }
    async let own = runner.run(build(into: "slot/areas/app"))
    async let other = runner.run(build(into: "other/areas/app"))
    #expect(await [own, other] == [.passed, .passed])
    #expect(active.withLock { $0.most } == 2)
  }

  @Test("a passing command is passed — catches exit 0 read as a failure")
  func passes() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(await runner.run(request("echo ok", in: directory)) == .passed)
  }

  @Test(
    "a command whose working directory doesn't exist fails naming that directory — catches the misleading could not start /bin/sh a missing area root gave"
  )
  func missingWorkingDirectoryIsNamed() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    // The area root `web` read against the subdirectory `web/` a worker had changed into.
    let missing = directory.appending(path: "web/web", directoryHint: .isDirectory)
    let outcome = await runner.run(request("echo ok", in: missing))
    guard case .failed(let exit, let tail, _) = outcome else {
      Issue.record("expected a failure, got \(outcome)")
      return
    }
    #expect(exit == 127)
    #expect(tail == "working directory \(missing.path) doesn't exist")
  }
}

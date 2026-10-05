import Darwin
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

@Suite("LiveAreaCommandRunner", .timeLimit(.minutes(5)))
struct LiveAreaCommandRunnerTests {
  /// Long enough that no command a test expects to finish runs out of it on a loaded machine; a
  /// command that hangs is ended by the suite's time limit instead.
  static let ample = Duration.seconds(3600)

  // A drain limit a busy machine's scheduling could outlast would cut a finished command's tail.
  let runner = LiveAreaCommandRunner(
    processRunner: LiveProcessRunner(
      baseEnvironment: ["PATH": "/usr/bin:/bin"], terminationGracePeriod: .milliseconds(200),
      postExitDrainLimit: .seconds(60)))

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
    _ command: String, in directory: URL, deadline: Duration = Self.ample,
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
    let ready = try HeldPipe()
    defer { ready.remove() }
    var lines = ready.lines().makeAsyncIterator()
    let clock = ShiftableClock()
    let runner = LiveAreaCommandRunner(
      processRunner: LiveProcessRunner(
        baseEnvironment: ["PATH": "/usr/bin:/bin"], terminationGracePeriod: .milliseconds(200),
        postExitDrainLimit: .seconds(60), now: clock.now))
    async let run = runner.run(
      request(
        "echo started; sleep 60 & echo $! > '\(pidFile.path)'; echo ready > '\(ready.path)'; wait",
        in: directory))

    // The deadline passes only once the command has printed and recorded its child, so a slow
    // start can't time it out before there is a group to kill.
    #expect(await lines.next() == "ready")
    clock.advance(by: Self.ample)
    let outcome = await run

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
    "a build into a worktree's DerivedData can't start while another builds there, and builds into 2 DerivedData run together — catches a gate's xcodebuild starting in a slot while the warm-up still builds there, which xcodebuild fails on its locked build database"
  )
  func oneBuildPerDerivedData() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    func build(into derivedData: String, deadline: Duration = Self.ample) -> AreaCommandRequest {
      AreaCommandRequest(
        area: "app", step: .build, command: "xcodebuild build", workingDirectory: directory.path,
        deadline: deadline, environment: [:], junitPath: nil,
        derivedDataSeed: DerivedDataSeedCopy(
          seed: directory.appending(path: "seed").path,
          destination: directory.appending(path: derivedData).path))
    }
    let passed = ProcessOutput(status: .exited(0), stdout: "", stderr: "")

    // While the first build runs, a second into the same DerivedData asks with next to no time to
    // wait: the first holds the lock until it answers, so it times out; a runner that let it in
    // would run it.
    let second = LiveAreaCommandRunner(
      processRunner: FakeProcessRunner { _ async throws(ProcessRunnerError) in passed })
    let alongside = Mutex<AreaCommandOutcome?>(nil)
    let unwaited = build(into: "slot/areas/app", deadline: .milliseconds(1))
    let first = LiveAreaCommandRunner(
      processRunner: FakeProcessRunner { _ async throws(ProcessRunnerError) -> ProcessOutput in
        let outcome = await second.run(unwaited)
        alongside.withLock { $0 = outcome }
        return passed
      })
    #expect(await first.run(build(into: "slot/areas/app")) == .passed)
    let refused = try #require(alongside.withLock { $0 })
    guard case .timedOut(let tail) = refused else {
      Issue.record("expected the second build to wait for the first, got \(refused)")
      return
    }
    #expect(tail.contains("for another build in"), "\(tail)")

    // Each build waits for the other to start, so 2 that may overlap both finish, and 2 run 1 at
    // a time never do: the suite's time limit fails them.
    let started = Arrivals()
    let together = LiveAreaCommandRunner(
      processRunner: FakeProcessRunner { _ async throws(ProcessRunnerError) -> ProcessOutput in
        started.arrive()
        _ = await started.reached(2)
        return passed
      })
    async let own = together.run(build(into: "slot/areas/app"))
    async let other = together.run(build(into: "other/areas/app"))
    #expect(await [own, other] == [.passed, .passed])
  }

  @Test(
    "2 swift builds that take turns in 1 scratch path run 1 at a time and the second's wait is added to the waits they share, while 1 build alone records a wait of 0 — catches 3 concurrent slices of the send-money trial waiting on SwiftPM's lock with no step showing the wait"
  )
  func swiftPMScratchPathTurnsAreTimed() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    // The wait is measured on a clock only the first build's command moves, so it reads the
    // same however busy the machine is.
    let base = ContinuousClock.now
    let offset = Mutex(Duration.zero)
    let reads = Arrivals()
    let now: @Sendable () -> ContinuousClock.Instant = {
      reads.arrive()
      return base + offset.withLock { $0 }
    }
    let holding = Arrivals()
    let calls = Mutex(0)
    let active = Mutex((now: 0, most: 0))
    let processes = FakeProcessRunner { _ async throws(ProcessRunnerError) -> ProcessOutput in
      active.withLock {
        $0.now += 1
        $0.most = max($0.most, $0.now)
      }
      let call = calls.withLock { count in
        count += 1
        return count
      }
      if call == 1 {
        // Holds the lock until the second build has read the clock to start its wait, then
        // takes 400 ms on it.
        let seen = reads.count
        holding.arrive()
        _ = await reads.reached(seen + 1)
        offset.withLock { $0 += .milliseconds(400) }
      }
      active.withLock { $0.now -= 1 }
      return ProcessOutput(status: .exited(0), stdout: "", stderr: "")
    }
    let runner = LiveAreaCommandRunner(processRunner: processes, now: now)
    let scratch = directory.appending(path: "slot/derived-data/prove/Feature").path
    func test(_ waits: BuildLockWaits) -> AreaCommandRequest {
      AreaCommandRequest(
        area: "Feature", step: .testFiles, command: "swift test --scratch-path '\(scratch)'",
        workingDirectory: directory.path, deadline: Self.ample, environment: [:],
        junitPath: nil, buildLock: BuildDirectoryLock(directory: scratch, waits: waits))
    }

    let shared = BuildLockWaits()
    async let first = runner.run(test(shared))
    _ = await holding.reached(1)
    let second = await runner.run(test(shared))
    #expect(await first == .passed)
    #expect(second == .passed)
    #expect(active.withLock { $0.most } == 1)
    #expect(shared.milliseconds == 400, "the second build waited out the first's 400 ms")

    let alone = BuildLockWaits()
    #expect(await runner.run(test(alone)) == .passed)
    #expect(alone.milliseconds == 0)
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

/// Counts arrivals, and lets a caller wait for a number of them with no bound of its own: a
/// deadline here would lose to a loaded machine that starts the last arrival late. A wait that
/// never ends is a regression the suite's time limit ends by cancelling it.
private final class Arrivals: Sendable {
  private struct State {
    var arrived = 0
    var waiting: [UUID: (count: Int, continuation: CheckedContinuation<Void, Never>)] = [:]
  }

  private let state = Mutex(State())

  var count: Int { state.withLock { $0.arrived } }

  func arrive() {
    let released = state.withLock { state in
      state.arrived += 1
      let ready = state.waiting.filter { $0.value.count <= state.arrived }
      for id in ready.keys { state.waiting[id] = nil }
      return ready.values.map(\.continuation)
    }
    for continuation in released { continuation.resume() }
  }

  /// Whether `count` have arrived, once they have or the wait is cancelled.
  func reached(_ count: Int) async -> Bool {
    let id = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let done = state.withLock { state in
          if state.arrived >= count || Task.isCancelled { return true }
          state.waiting[id] = (count, continuation)
          return false
        }
        if done { continuation.resume() }
      }
    } onCancel: {
      state.withLock { $0.waiting.removeValue(forKey: id) }?.continuation.resume()
    }
    return state.withLock { $0.arrived >= count }
  }
}

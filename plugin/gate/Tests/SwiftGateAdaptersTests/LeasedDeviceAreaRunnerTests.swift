import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

@Suite("an area's xcodebuild test runs on a leased clone, retried once on a runner launch failure")
struct LeasedDeviceAreaRunnerTests {
  /// The `test` and `build` commands discovery wrote for a brownfield iOS trial.
  static func trialCommand(_ key: String) throws -> String {
    let config = try Fixture.text("BrownfieldTrial/aidoku-validation-config.toml")
    let prefix = "\(key) = \""
    return try #require(
      config.split(separator: "\n").first { $0.hasPrefix(prefix) }
        .map { String($0.dropFirst(prefix.count).dropLast()) })
  }

  static func request(_ step: AreaStep, _ command: String) -> AreaCommandRequest {
    AreaCommandRequest(
      area: "Aidoku", step: step, command: command, workingDirectory: "/work/tree",
      deadline: .seconds(600), environment: [:], junitPath: nil)
  }

  /// The last 40 lines of the captured busy-simulator run, as an area command's tail holds them.
  static func busyTail() throws -> String {
    try Fixture.text("QA/runner-launch/busy-1.tail.txt")
      .split(separator: "\n", omittingEmptySubsequences: false).suffix(40).joined(separator: "\n")
  }

  /// Answers each call in turn from `outcomes`; the last answers every later call.
  static func replaying(_ outcomes: [AreaCommandOutcome]) -> FakeAreaCommandRunner {
    let calls = Mutex(0)
    return FakeAreaCommandRunner { _ in
      let index = calls.withLock {
        $0 += 1
        return $0 - 1
      }
      return outcomes[min(index, outcomes.count - 1)]
    }
  }

  @Test(
    "the area's test step runs on 1 leased clone with `-destination 'id=<clone>'`, given back after — catches a gate's test step on the simulator every session shares"
  )
  func testStepRunsOnALeasedClone() async throws {
    let base = Self.replaying([.passed])
    let leases = FakeTestDeviceLeases()
    let runner = LeasedDeviceAreaRunner(base: base, leases: leases)

    let outcome = await runner.run(Self.request(.test, try Self.trialCommand("test")))

    #expect(outcome == .passed)
    #expect(leases.destinations == [XcodeTestDestination(device: "iPhone 17", os: nil)])
    #expect((leases.entered, leases.left) == (1, 1))
    let command = try #require(base.requests.first?.command)
    #expect(command.contains("-destination 'id=\(FakeDevices.device.udid)'"), "\(command)")
  }

  @Test(
    "the area's generic build runs as written and leases nothing — catches a clone booted for a step that launches no app"
  )
  func buildRunsAsWritten() async throws {
    let base = Self.replaying([.passed])
    let leases = FakeTestDeviceLeases()
    let build = try Self.trialCommand("build")

    _ = await LeasedDeviceAreaRunner(base: base, leases: leases).run(Self.request(.build, build))
    _ = await LeasedDeviceAreaRunner(base: base, leases: leases)
      .run(Self.request(.test, try Self.trialCommand("test")))

    #expect(base.requests.first?.command == build)
    #expect(leases.destinations.count == 1)
  }

  @Test(
    "with no clone to be had, the test step runs as written — catches a gate blocked because the machine's simulator slots were full"
  )
  func leaseFailureRunsAsWritten() async throws {
    let base = Self.replaying([.passed])
    let test = try Self.trialCommand("test")

    let leases = FakeTestDeviceLeases(failure: TestDeviceLeaseError(reason: "no slot"))

    let outcome = await LeasedDeviceAreaRunner(base: base, leases: leases)
      .run(Self.request(.test, test))

    #expect(outcome == .passed)
    #expect(leases.destinations == [XcodeTestDestination(device: "iPhone 17", os: nil)])
    #expect(base.requests.map(\.command) == [test])
  }

  @Test(
    "the captured busy-simulator failure then a pass passes after 1 retry on the same clone — catches a test step failed by the machine, not the code"
  )
  func launchFailureIsRetriedOnce() async throws {
    let base = Self.replaying([.failed(exit: 65, tail: try Self.busyTail(), junit: nil), .passed])
    let leases = FakeTestDeviceLeases()

    let outcome = await LeasedDeviceAreaRunner(base: base, leases: leases)
      .run(Self.request(.test, try Self.trialCommand("test")))

    #expect(outcome == .passed)
    #expect(base.requests.count == 2)
    #expect(leases.entered == 1)
  }

  @Test(
    "the captured busy-simulator failure twice stays the step's failure, its tail headed by the launch failure; a real failure isn't retried — catches a failure retried whatever it was, or a launch failure with no word of why"
  )
  func launchFailureTwiceNamesIt() async throws {
    let busy = AreaCommandOutcome.failed(exit: 65, tail: try Self.busyTail(), junit: nil)
    let base = Self.replaying([busy])

    let outcome = await LeasedDeviceAreaRunner(base: base, leases: FakeTestDeviceLeases())
      .run(Self.request(.test, try Self.trialCommand("test")))

    #expect(base.requests.count == 2)
    guard case .failed(65, let tail, _) = outcome else {
      Issue.record("expected exit 65, got \(outcome)")
      return
    }
    #expect(tail.hasPrefix("the test runner"), "\(tail.prefix(200))")

    let compile = AreaCommandOutcome.failed(
      exit: 65,
      tail: try Fixture.text("BrownfieldTrial/aidoku-validation-3-test-compile.tail.txt"),
      junit: nil)
    let real = Self.replaying([compile])
    let failed = await LeasedDeviceAreaRunner(base: real, leases: FakeTestDeviceLeases())
      .run(Self.request(.test, try Self.trialCommand("test")))
    #expect(failed == compile)
    #expect(real.requests.count == 1)
  }
}

@Suite("a leased device held across a run's test commands")
struct SimulatorDeviceHoldTests {
  @Test(
    "2 asks share 1 leased device, release gives it back, and a later ask leases afresh — catches a clone booted per command, or one left held after the run"
  )
  func holdsUntilReleased() async throws {
    let leases = FakeTestDeviceLeases()
    let destination = XcodeTestDestination(device: "iPhone 17", os: nil)
    let provider = try await leases.devices(for: destination).get()
    let hold = SimulatorDeviceHold(provider: provider)

    let first = await hold.device()
    let second = await hold.device()
    #expect(try first.get() == FakeDevices.device)
    #expect(try second.get() == FakeDevices.device)
    #expect((leases.entered, leases.left) == (1, 0))

    await hold.release()
    #expect((leases.entered, leases.left) == (1, 1))

    _ = await hold.device()
    await hold.release()
    #expect((leases.entered, leases.left) == (2, 2))
  }

  @Test(
    "a clone that can't be made is the hold's failure, naming why — catches a failed lease read as a device"
  )
  func failedCloneIsAFailure() async {
    let hold = SimulatorDeviceHold(
      provider: FakeDevices(
        failure: .selection(
          .baseDeviceNotFound(device: "iPhone 17", os: "26.2", installedRuntimes: []))))

    let result = await hold.device()
    await hold.release()

    guard case .failure(let error) = result else {
      Issue.record("expected a failure, got \(result)")
      return
    }
    #expect(error.reason.contains("iPhone 17"), "\(error.reason)")
  }
}

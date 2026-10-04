import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

/// `FakeAgentDevice`, with a screenshot that writes its file as the real CLI does and snapshots
/// answered in turn from a list, so a test can change the screen, or lose the device, between
/// two snapshots. The last answer repeats.
final class ScreenAgentDevice: AgentDevice {
  let fake: FakeAgentDevice
  private let pngBytes: Data
  private let snapshots: Mutex<[Result<Data, AgentDeviceError>]>

  init(
    fake: FakeAgentDevice = FakeAgentDevice(), png: Data,
    snapshots: [Result<Data, AgentDeviceError>]
  ) {
    self.fake = fake
    self.pngBytes = png
    self.snapshots = Mutex(snapshots)
  }

  func version() async throws(AgentDeviceError) -> String { try await fake.version() }
  func open(bundleID: String, launchArguments: [String], on target: AgentDeviceTarget)
    async throws(AgentDeviceError) -> AgentDeviceOpened
  { try await fake.open(bundleID: bundleID, launchArguments: launchArguments, on: target) }
  func snapshotJSON(on target: AgentDeviceTarget) async throws(AgentDeviceError) -> Data {
    _ = try await fake.snapshotJSON(on: target)
    return try snapshots.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] }.get()
  }
  func screenshot(to path: String, on target: AgentDeviceTarget) async throws(AgentDeviceError) {
    try await fake.screenshot(to: path, on: target)
    try? pngBytes.write(to: URL(filePath: path))
  }
  func appState(on target: AgentDeviceTarget) async throws(AgentDeviceError)
    -> AgentDeviceAppState
  { try await fake.appState(on: target) }
  func sessions(on target: AgentDeviceTarget) async throws(AgentDeviceError)
    -> [AgentDeviceSession]
  { try await fake.sessions(on: target) }
  func waitForText(_ text: String, timeoutMilliseconds: Int, on target: AgentDeviceTarget)
    async throws(AgentDeviceError)
  { try await fake.waitForText(text, timeoutMilliseconds: timeoutMilliseconds, on: target) }
  func batch(stepsFile: String, on target: AgentDeviceTarget) async throws(AgentDeviceError)
    -> AgentDeviceBatchResult
  { try await fake.batch(stepsFile: stepsFile, on: target) }
  func recordStart(to path: String, on target: AgentDeviceTarget) async throws(AgentDeviceError) {
    try await fake.recordStart(to: path, on: target)
  }
  func recordStop(on target: AgentDeviceTarget) async throws(AgentDeviceError) -> String {
    try await fake.recordStop(on: target)
  }
  func contactSheet(video: String, to sheet: String) async throws(AgentDeviceError) -> String {
    try await fake.contactSheet(video: video, to: sheet)
  }
  func logs(on target: AgentDeviceTarget) async throws(AgentDeviceError) -> String {
    try await fake.logs(on: target)
  }
  func networkDump(limit: Int, on target: AgentDeviceTarget) async throws(AgentDeviceError)
    -> Data
  { try await fake.networkDump(limit: limit, on: target) }
  func trace(_ action: AgentDeviceTraceAction, path: String, on target: AgentDeviceTarget)
    async throws(AgentDeviceError)
  { try await fake.trace(action, path: path, on: target) }
  func close(on target: AgentDeviceTarget) async throws(AgentDeviceError) {
    try await fake.close(on: target)
  }
  func releaseStale(udid: String) async throws(AgentDeviceError) {
    try await fake.releaseStale(udid: udid)
  }
}

@Suite("sim snap")
struct SimSnapTests {
  static let runID = "20261004T120000Z-1a2b3c4d"
  static let worktree = "/repos/app"
  static let png = Data("png bytes".utf8)

  let root = TestTemporaryDirectory.root.appending(
    path: "sim-snap-\(UUID().uuidString)", directoryHint: .isDirectory)
  var store: SimLeaseStore { SimLeaseStore(directory: root.appending(path: "locks/sim-leases")) }

  func simDirectory(_ runID: String) -> URL {
    root.appending(path: "state/runs/\(runID)/sim", directoryHint: .isDirectory)
  }

  static func lease(
    _ runID: String = runID, worktree: String = worktree, holderPID: Int32 = 4242,
    session: String? = SimSession.agentDeviceSessionName(runID: runID)
  ) -> SimLease {
    SimLease(
      runID: runID, worktree: worktree, udid: "MADE-1", holderPID: holderPID, session: session)
  }

  /// A run as `sim up` leaves it: the lease and `session.json`.
  func started(_ lease: SimLease = Self.lease()) throws {
    try store.write(lease)
    let directory = simDirectory(lease.runID)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try SimSession(
      agentDeviceVersion: AgentDevicePin.version, udid: lease.udid, deviceType: "iPhone 17",
      runtime: "com.apple.CoreSimulator.SimRuntime.iOS-26-2", bundleID: "com.example.SampleApp",
      scenario: "fixed-fact", headCommit: "0123456789abcdef0123456789abcdef01234567",
      startedAt: Date(timeIntervalSince1970: 1_791_115_200)
    ).encoded().write(to: directory.appending(path: SimSession.fileName))
  }

  func device(snapshots: [Result<Data, AgentDeviceError>]? = nil) throws -> ScreenAgentDevice {
    ScreenAgentDevice(
      png: Self.png,
      snapshots: try snapshots ?? [.success(Fixture.data("AgentDevice/snapshot.stdout"))])
  }

  func snap(
    _ device: ScreenAgentDevice, runID: String? = runID, label: String = "home",
    assert: String? = nil, worktree: String = worktree, alive: Set<Int32> = [4242]
  ) async -> Result<SimSnapped, SimSnapFailure> {
    let directories = root
    let dependencies = SimSnap.Dependencies(
      agentDevice: device, leases: store, isAlive: { alive.contains($0) },
      clock: VirtualHoldClock().clock)
    return await SimSnap(dependencies: dependencies).run(
      SimSnap.Request(
        worktree: worktree, runID: runID, label: label, assert: assert,
        simDirectory: {
          directories.appending(path: "state/runs/\($0)/sim", directoryHint: .isDirectory)
        }))
  }

  static func failure(_ result: Result<SimSnapped, SimSnapFailure>) -> SimSnapFailure? {
    if case .failure(let failure) = result { failure } else { nil }
  }

  func stepFiles(_ runID: String = runID) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(
      atPath: simDirectory(runID).appending(path: SimStep.directoryName).path)) ?? []).sorted()
  }

  func stepLog(_ runID: String = runID) -> Data? {
    try? Data(contentsOf: simDirectory(runID).appending(path: SimStep.logFileName))
  }

  @Test(
    "2 snaps number 001 and 002 with the captured tree's bytes on disk unchanged, on the lease's device and session — catches rewritten evidence or a snap of another device"
  )
  func twoSnaps() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    try started()
    let device = try device()
    let tree = try Fixture.data("AgentDevice/snapshot.stdout")

    let first = try await snap(device, label: "home").get()
    let second = try await snap(device, label: "after tap", assert: "Counter").get()

    #expect(first.step.n == 1 && second.step.n == 2)
    #expect(stepFiles() == ["001.png", "001.tree.json", "002.png", "002.tree.json"])
    let directory = simDirectory(Self.runID)
    #expect(try Data(contentsOf: directory.appending(path: "steps/001.tree.json")) == tree)
    #expect(try Data(contentsOf: directory.appending(path: "steps/002.tree.json")) == tree)
    #expect(try Data(contentsOf: directory.appending(path: "steps/002.png")) == Self.png)
    #expect(second.step.settled == true)
    #expect(second.simDirectory == directory.path)
    let steps = try SimStep.decodeLog(try #require(stepLog()))
    #expect(steps.map(\.label) == ["home", "after tap"])
    #expect(steps.map(\.assert) == [nil, "Counter"])
    let target = AgentDeviceTarget(
      udid: "MADE-1", session: SimSession.agentDeviceSessionName(runID: Self.runID))
    #expect(device.fake.calls.count == 6)
    #expect(device.fake.calls.allSatisfy { call in
      switch call {
      case .snapshot(let used), .screenshot(_, let used): used == target
      default: false
      }
    })
  }

  @Test(
    "a step with no --assert omits the key from its line — catches a placeholder assertion sim verify would search the tree for"
  )
  func noAssert() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    try started()
    _ = try await snap(try device()).get()
    let line = try #require(stepLog())
    let object = try #require(
      try JSONSerialization.jsonObject(with: line.prefix { $0 != UInt8(ascii: "\n") })
        as? [String: Any])
    #expect(object["assert"] == nil)
    #expect(object["label"] as? String == "home")
  }

  @Test(
    "a screen that changes between the two snapshots records settled false — catches a screenshot of a different screen than its tree passing as settled"
  )
  func unsettled() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    try started()
    let captured = try Fixture.text("AgentDevice/snapshot.stdout")
    let changed = Data(
      captured.replacingOccurrences(of: "\"label\": \"SampleApp\"", with: "\"label\": \"Next\"")
        .utf8)
    let snapped = try await snap(try device(snapshots: [.success(Data(captured.utf8)), .success(changed)])).get()
    #expect(snapped.step.settled == false)
    #expect(
      try Data(contentsOf: simDirectory(Self.runID).appending(path: "steps/001.tree.json"))
        == Data(captured.utf8))
  }

  @Test(
    "a lease from another worktree is refused with sim.not-owner, calls no device, and writes nothing — catches one worktree recording steps on another's run"
  )
  func otherWorktree() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    try started(Self.lease(worktree: "/repos/app-other"))
    let device = try device()

    let failure = try #require(Self.failure(await snap(device)))

    #expect(failure.rule == .notOwner)
    #expect(failure.verdict == .red)
    #expect(failure.message.contains("/repos/app-other"))
    #expect(device.fake.calls.isEmpty)
    #expect(stepFiles().isEmpty)
    #expect(stepLog() == nil)
  }

  @Test(
    "the captured unknown-device error exits RED as sim.session-gone with no step line and no orphan PNG, and is logged — catches a half step left as evidence"
  )
  func sessionGone() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    try started()
    let gone = try AgentDeviceError.decodeFailure(
      try Fixture.data("AgentDevice/open-unknown-udid.stdout"))
    for call in ["snapshot", "screenshot"] {
      let device = try device()
      device.fake.update { $0.failures[call] = .failed(command: call, gone) }

      let failure = try #require(Self.failure(await snap(device)))

      #expect(failure.rule == .sessionGone)
      #expect(failure.verdict == .red)
      #expect(failure.runID == Self.runID)
      #expect(stepFiles().isEmpty)
      #expect(stepLog() == nil)
    }
    let log = try String(
      contentsOf: simDirectory(Self.runID).appending(path: SimSession.logFileName),
      encoding: .utf8)
    #expect(log.contains("DEVICE_NOT_FOUND"))
  }

  @Test(
    "a gone second snapshot after the screenshot also leaves no PNG behind — catches a screenshot kept without its step"
  )
  func goneAfterScreenshot() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    try started()
    let gone = try AgentDeviceError.decodeFailure(
      try Fixture.data("AgentDevice/open-unknown-udid.stdout"))
    _ = try await snap(try device()).get()
    let failing = try device(snapshots: [
      .success(Fixture.data("AgentDevice/snapshot.stdout")),
      .failure(.failed(command: "snapshot", gone)),
    ])

    let failure = try #require(Self.failure(await snap(failing)))

    #expect(failure.rule == .sessionGone)
    #expect(stepFiles() == ["001.png", "001.tree.json"])
    #expect(try SimStep.decodeLog(try #require(stepLog())).count == 1)
  }

  @Test(
    "a dead holder or a lease with no session is sim.session-gone without calling the device — catches a snap on a device the holder already deleted"
  )
  func deadHolder() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    try started()
    let device = try device()
    let dead = try #require(Self.failure(await snap(device, alive: [])))
    #expect(dead.rule == .sessionGone)
    #expect(dead.message.contains("4242"))

    try store.write(Self.lease(session: nil))
    let unopened = try #require(Self.failure(await snap(device)))
    #expect(unopened.rule == .sessionGone)
    #expect(device.fake.calls.isEmpty)
  }

  @Test(
    "with no run id a snap takes this worktree's newest live lease, skipping another worktree's and a dead holder's — catches a step written into the wrong run"
  )
  func defaultRun() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let older = "20261004T110000Z-00000001"
    let newest = "20261004T130000Z-00000003"
    let dead = "20261004T140000Z-00000004"
    let foreign = "20261004T150000Z-00000005"
    try started(Self.lease(older))
    try started(Self.lease(newest))
    try started(Self.lease(dead, holderPID: 999))
    try started(Self.lease(foreign, worktree: "/repos/app-other"))

    let snapped = try await snap(try device(), runID: nil).get()

    #expect(snapped.runID == newest)
    #expect(stepFiles(newest) == ["001.png", "001.tree.json"])
    #expect(stepFiles(older).isEmpty && stepFiles(dead).isEmpty && stepFiles(foreign).isEmpty)
  }

  @Test(
    "with no run id and no live lease of its own a snap is sim.session-gone naming sim up — catches a snap that quietly uses another worktree's run"
  )
  func noRun() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    try started(Self.lease(worktree: "/repos/app-other"))
    let failure = try #require(Self.failure(await snap(try device(), runID: nil)))
    #expect(failure.rule == .sessionGone)
    #expect(failure.message.contains("sim up"))
    #expect(stepFiles().isEmpty)
  }

  @Test(
    "the captured DEVICE_IN_USE refusal is BLOCKED sim.driver-failed, logged, with no step — catches a driver failure reported as an app defect"
  )
  func driverFailed() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    try started()
    let refusal = try AgentDeviceError.decodeFailure(
      try Fixture.data("AgentDevice/open-device-in-use.stdout"))
    let device = try device()
    device.fake.update { $0.failures["screenshot"] = .failed(command: "screenshot", refusal) }

    let failure = try #require(Self.failure(await snap(device)))

    #expect(failure.rule == .driverFailed)
    #expect(failure.verdict == .blocked)
    #expect(failure.message.contains(SimSession.logFileName))
    #expect(stepFiles().isEmpty)
    let log = try String(
      contentsOf: simDirectory(Self.runID).appending(path: SimSession.logFileName),
      encoding: .utf8)
    #expect(log.contains("DEVICE_IN_USE"))
  }
}

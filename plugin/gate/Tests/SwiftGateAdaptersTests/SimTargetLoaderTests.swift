import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// `sim up`, `sim hold` and `qa run`'s flow rows read their target through ``SimTargetLoader``, so
/// a brownfield clone, which commits no `.swiftgate.toml`, builds from its `xcode` area.
@Suite("sim target loader")
struct SimTargetLoaderTests {
  static let runID = "20261004T120000Z-1a2b3c4d"
  static let udid = "MADE-1"

  /// A clone with a `.git` directory, holding `brownfield` as its common dir's `config.toml` and
  /// `owned` as its `.swiftgate.toml`.
  static func clone(brownfield: String? = nil, owned: String? = nil) throws -> URL {
    let root = try TestTemporaryDirectory.make("sim-target")
    let state = root.appending(path: ".git/swift-harness", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    if let brownfield {
      try Data(brownfield.utf8).write(to: state.appending(path: "config.toml"))
    }
    if let owned {
      try Data(owned.utf8).write(to: root.appending(path: ".swiftgate.toml"))
    }
    return root
  }

  static func aidoku() throws -> String {
    try Fixture.text("BrownfieldTrial/aidoku-validation-config.toml")
  }

  static func failure<T>(_ result: Result<T, SimUpFailure>) -> SimUpFailure? {
    if case .failure(let failure) = result { failure } else { nil }
  }

  @Test(
    "a brownfield clone with no .swiftgate.toml builds the xcode area's project and scheme on its destination's device — catches sim up refusing every brownfield clone with no .swiftgate.toml"
  )
  func brownfieldCloneRunsSimUp() async throws {
    let root = try Self.clone(brownfield: try Self.aidoku())
    defer { TestTemporaryDirectory.remove(root) }
    try FileManager.default.createDirectory(
      at: root.appending(path: "Aidoku.xcodeproj"), withIntermediateDirectories: true)

    let target = try SimTargetLoader.load(worktree: root).get()
    #expect(target.scheme == "Aidoku")
    #expect(target.container == .project("Aidoku.xcodeproj"))
    #expect(target.device == "iPhone 17")
    #expect(target.os == nil)
    #expect(target.scenarios.isEmpty)

    let store = SimLeaseStore(directory: root.appending(path: "locks/sim-leases"))
    let launcher = FakeHolderLauncher(store: store, udid: Self.udid)
    let xcodebuild = FakeXcodebuild()
    let simctl = InstallRecordingSimctl(devices: [SimUpTests.device])
    let dependencies = SimUp.Dependencies(
      agentDevice: FakeAgentDevice(), leases: store, launcher: launcher, xcodebuild: xcodebuild,
      simctl: simctl, bundles: FixedAppBundle(result: .success(SimUpTests.app)),
      git: FakeGit(revisions: ["HEAD": SimUpTests.head]), isAlive: { _ in true },
      terminate: { _ in }, slotHolders: { [] }, clock: VirtualHoldClock().clock,
      now: { Date(timeIntervalSince1970: 1_791_115_200) })
    let result = await SimUp(dependencies: dependencies, pollInterval: .seconds(1)).run(
      SimUp.Request(
        worktree: root, target: target, scenario: nil, runID: Self.runID,
        simDirectory: root.appending(path: ".harness/runs/\(Self.runID)/sim"),
        derivedDataPath: "/dd", swiftgateExecutable: "/plugin/bin/sg"))

    let started = try result.get()
    #expect(started.udid == Self.udid)
    let build = try #require(xcodebuild.buildRequests.first)
    #expect(build.scheme == "Aidoku")
    #expect(build.container == .project(path: root.appending(path: "Aidoku.xcodeproj").path))
    #expect(launcher.launches.map(\.arguments) == [["sim", "hold", "--run", Self.runID]])
  }

  @Test(
    "an owned repository still reads its .swiftgate.toml, device and iOS version included — catches the owned profile losing its pinned simulator"
  )
  func ownedRepositoryReadsSwiftgateToml() throws {
    let toml = """
      schema = 1
      xcode = "26.2"
      app_scheme = "App"
      packages = ["Packages/*"]

      [simulator]
      device = "iPhone 16"
      os = "18.4"

      [[scenarios]]
      name = "fixed-fact"
      reason = "one fixed fact"

      """
    let root = try Self.clone(owned: toml)
    defer { TestTemporaryDirectory.remove(root) }

    let target = try SimTargetLoader.load(worktree: root).get()

    let config = try #require(try ConfigLoader().load(repositoryRoot: root))
    #expect(target == SimTarget(owned: config))
    #expect(target.scheme == "App" && target.container == .worktreeRoot)
    #expect(target.device == "iPhone 16" && target.os == "18.4")
    #expect(target.scenarios.map(\.name) == ["fixed-fact"])
  }

  @Test(
    "a brownfield clone with no xcode area is BLOCKED naming the missing area and no absolute path — catches a node or go clone reaching xcodebuild"
  )
  func brownfieldWithoutXcodeAreaBlocks() throws {
    let root = try Self.clone(
      brownfield: try Fixture.text("BrownfieldTrial/memos-4-config.toml"))
    defer { TestTemporaryDirectory.remove(root) }

    let failure = try #require(Self.failure(SimTargetLoader.load(worktree: root)))

    #expect(failure.verdict == .blocked)
    #expect(failure.message.contains("no xcode area"), "\(failure.message)")
    #expect(failure.message.contains("memos") && failure.message.contains("web"))
    #expect(!failure.message.contains(root.path), "\(failure.message)")
  }

  @Test(
    "a clone with neither config is BLOCKED naming both files — catches a brownfield clone told only about .swiftgate.toml"
  )
  func noConfigBlocks() throws {
    let root = try Self.clone()
    defer { TestTemporaryDirectory.remove(root) }

    let failure = try #require(Self.failure(SimTargetLoader.load(worktree: root)))

    #expect(failure.verdict == .blocked)
    #expect(failure.message.contains(".swiftgate.toml"), "\(failure.message)")
    #expect(failure.message.contains("swiftgate discover --apply"), "\(failure.message)")
    #expect(!failure.message.contains(root.path), "\(failure.message)")
  }

  static func device(_ name: String, _ runtime: String, available: Bool = true)
    -> SimulatorDevice
  {
    SimulatorDevice(
      udid: "\(name)-\(runtime)", name: name,
      runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-\(runtime)", state: "Shutdown",
      isAvailable: available)
  }

  @Test(
    "with no iOS version pinned, the holder clones the newest runtime holding an available device of that name, never a harness clone's — catches a brownfield hold that can never find its base device"
  )
  func newestRuntimeForBrownfieldDevice() async throws {
    let target = SimTarget(
      scheme: "Aidoku", container: .project("Aidoku.xcodeproj"), device: "iPhone 17", os: nil)
    let simctl = FakeSimctl(devices: [
      Self.device("iPhone 17", "26-0"), Self.device("iPhone 17", "26-10"),
      Self.device("iPhone 17", "26-2"), Self.device("iPhone 17", "27-0", available: false),
      Self.device("swift-harness-4242-tok", "27-1"), Self.device("iPhone 16", "27-2"),
    ])

    let simulator = try await SimTargetLoader.simulator(for: target, simctl: simctl).get()

    #expect(simulator.device == "iPhone 17")
    #expect(simulator.os == "26.10")
    #expect(simulator.maxConcurrent == SimulatorConfig.defaultMaxConcurrent)
  }

  @Test(
    "with no device of that name on any runtime the holder is BLOCKED naming the device; a pinned version needs no device list — catches a hold waiting on a device that doesn't exist"
  )
  func noDeviceBlocks() async throws {
    let brownfield = SimTarget(
      scheme: "Aidoku", container: .project("Aidoku.xcodeproj"), device: "iPhone 17", os: nil)
    let none = FakeSimctl(devices: [Self.device("iPhone 16", "26-2")])
    let failure = try #require(
      Self.failure(await SimTargetLoader.simulator(for: brownfield, simctl: none)))
    #expect(failure.verdict == .blocked)
    #expect(failure.message.contains("\"iPhone 17\""), "\(failure.message)")

    let pinned = SimTarget(
      scheme: "App", container: .worktreeRoot, device: "iPhone 17", os: "26.2")
    let simulator = try await SimTargetLoader.simulator(for: pinned, simctl: none).get()
    #expect(simulator.os == "26.2")
  }
}

import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("DerivedDataSeeding")
struct DerivedDataSeedingTests {
  /// A seed laid out as the trial's warm-up DerivedData: resolved packages whose
  /// `workspace-state.json` is the captured one, beside build products and a module cache.
  private struct Rig {
    let base: URL
    var seed: String { base.appending(path: "caches/derived-data/Aidoku").path(percentEncoded: false) }
    var destination: String {
      base.appending(path: "worktrees/task/swift-harness/derived-data/areas/Aidoku")
        .path(percentEncoded: false)
    }

    init(withPackages: Bool = true) throws {
      base = TestTemporaryDirectory.root.appending(
        path: "derived-data-seeding-\(UUID().uuidString)", directoryHint: .isDirectory)
      let seed = URL(filePath: base.appending(path: "caches/derived-data/Aidoku").path)
      try write("Build/Products/Debug-iphonesimulator/Aidoku.swiftmodule/x", in: seed)
      try write("ModuleCache.noindex/Foundation.pcm", in: seed)
      guard withPackages else { return }
      try write("SourcePackages/checkouts/Nuke/Package.swift", in: seed)
      try write(
        "SourcePackages/artifacts/texture/AsyncDisplayKit/AsyncDisplayKit.xcframework/Info.plist",
        in: seed)
      let state = try Fixture.text("BrownfieldTrial/aidoku-workspace-state.json")
        .replacingOccurrences(of: "/SEED", with: seed.path(percentEncoded: false))
      try write("SourcePackages/workspace-state.json", state, in: seed)
    }

    private func write(_ relative: String, _ text: String = "x", in root: URL) throws {
      let url = root.appending(path: relative)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(text.utf8).write(to: url)
    }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
  }

  @Test(
    "a worktree's DerivedData gets the seed's resolved packages, with the captured state's artifact paths moved to it, and none of the seed's build products or module cache — catches a worktree resolving packages from scratch, reading the seed's artifacts, or a build database that deletes the seed's products as stale"
  )
  func seedsResolvedPackagesOnly() async throws {
    let rig = try Rig()
    defer { try? FileManager.default.removeItem(at: rig.base) }

    let outcome = await DerivedDataSeeding().seed(
      DerivedDataSeedCopy(seed: rig.seed, destination: rig.destination))

    #expect(outcome == .seeded)
    #expect(rig.exists("\(rig.destination)/SourcePackages/checkouts/Nuke/Package.swift"))
    #expect(!rig.exists("\(rig.destination)/Build"))
    #expect(!rig.exists("\(rig.destination)/ModuleCache.noindex"))
    let state = try String(
      contentsOfFile: "\(rig.destination)/SourcePackages/workspace-state.json", encoding: .utf8)
    #expect(!state.contains(rig.seed + "/"))
    #expect(
      state.contains(
        "\"\(rig.destination)/SourcePackages/artifacts/texture/AsyncDisplayKit/AsyncDisplayKit.xcframework\""
      ))
    #expect(
      rig.exists("\(rig.seed)/Build/Products/Debug-iphonesimulator/Aidoku.swiftmodule/x"),
      "the seed keeps its products")
    let left = try FileManager.default.contentsOfDirectory(
      atPath: URL(filePath: rig.destination).deletingLastPathComponent().path)
    #expect(left == ["Aidoku"], "no staging folder is left beside it")
  }

  @Test(
    "a worktree whose DerivedData exists keeps it, and a seed with no resolved packages seeds nothing — catches a second slice discarding the first one's build, or an empty folder that hides a later seed"
  )
  func existingOrMissing() async throws {
    let rig = try Rig()
    defer { try? FileManager.default.removeItem(at: rig.base) }
    try FileManager.default.createDirectory(
      atPath: "\(rig.destination)/Build", withIntermediateDirectories: true)
    #expect(
      await DerivedDataSeeding().seed(
        DerivedDataSeedCopy(seed: rig.seed, destination: rig.destination)) == .alreadyPresent)
    #expect(!rig.exists("\(rig.destination)/SourcePackages"))

    let bare = try Rig(withPackages: false)
    defer { try? FileManager.default.removeItem(at: bare.base) }
    #expect(
      await DerivedDataSeeding().seed(
        DerivedDataSeedCopy(seed: bare.seed, destination: bare.destination)) == .noSeed)
    #expect(!bare.exists(bare.destination))
  }

  @Test(
    "the area runner seeds the request's DerivedData before its command runs — catches a seed the build never sees"
  )
  func runnerSeedsFirst() async throws {
    let rig = try Rig()
    defer { try? FileManager.default.removeItem(at: rig.base) }
    let runner = LiveAreaCommandRunner(
      processRunner: LiveProcessRunner(baseEnvironment: ["PATH": "/usr/bin:/bin"]))

    let outcome = await runner.run(
      AreaCommandRequest(
        area: "Aidoku", step: .build,
        command: "test -f '\(rig.destination)/SourcePackages/checkouts/Nuke/Package.swift'",
        workingDirectory: rig.base.path(percentEncoded: false), deadline: .seconds(20),
        environment: [:], junitPath: nil,
        derivedDataSeed: DerivedDataSeedCopy(seed: rig.seed, destination: rig.destination)))

    #expect(outcome == .passed)
  }
}

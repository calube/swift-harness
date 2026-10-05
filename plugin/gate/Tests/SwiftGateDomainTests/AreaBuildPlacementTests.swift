import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("where a checkout's area commands build")
struct AreaBuildPlacementTests {
  private static let common = URL(filePath: "/clone/.git", directoryHint: .isDirectory)
  private static let slot = BrownfieldStateLayout(
    commonDir: common,
    gitDir: URL(filePath: "/clone/.git/worktrees/repo-spec.slot-3", directoryHint: .isDirectory))
  private static let main = BrownfieldStateLayout(commonDir: common, gitDir: common)
  private static let shared = "/clone/.git/swift-harness/caches/swiftpm-scratch/AppFeature"

  /// 1 of the send-money trial's discovered areas, with the commands discovery wrote for it.
  private static func area(_ name: String) throws -> BrownfieldArea {
    let config = try Fixture.text("BrownfieldTrial/send-money-3-config.toml")
    let section = try #require(
      config.components(separatedBy: "[[areas]]").first { $0.contains("name = \"\(name)\"") })
    func value(_ key: String) -> String? {
      let prefix = "\(key) = \""
      return section.split(separator: "\n").first { $0.hasPrefix(prefix) }
        .map { String($0.dropFirst(prefix.count).dropLast()) }
    }
    return BrownfieldArea(
      name: name, root: value("root") ?? ".", language: .swift,
      kind: value("kind") == "xcode" ? .xcode : .swiftpm, test: value("test"),
      testFiles: value("test_files"), lint: nil, build: value("build"), e2e: nil,
      testGlobs: [], packs: [], xcode: nil)
  }

  private static func request(_ area: BrownfieldArea, _ command: String, in directory: String)
    -> AreaCommandRequest
  {
    AreaCommandRequest(
      area: area.name, step: .build, command: command, workingDirectory: directory,
      deadline: .seconds(600), environment: [:], junitPath: nil)
  }

  @Test(
    "the trial's swiftpm build, test and test_files commands build in the area's shared scratch path from a task slot and from the main checkout, and that path is the step's build directory — catches each new slot's first slice compiling the area's dependencies cold in a .build of its own, 180 s in the send-money trial"
  )
  func swiftPMCheckoutsShareTheScratchPath() throws {
    let area = try Self.area("AppFeature")
    let commands = try [area.build, area.test, area.testFiles].map { try #require($0) }
    for (layout, directory) in [
      (Self.slot, "/work/repo-spec.slot-3/Packages/AppFeature"),
      (Self.main, "/clone/Packages/AppFeature"),
    ] {
      for command in commands {
        let placed = AreaBuildPlacement.checkout(
          Self.request(area, command, in: directory), kind: .swiftpm, layout: layout)
        #expect(placed.command.contains(" --scratch-path '\(Self.shared)'"), "\(command)")
        #expect(placed.workingDirectory == directory)
        #expect(
          XcodeDerivedData.buildDirectories(placed, kind: .swiftpm, layout: layout)
            == [Self.shared])
      }
    }
    // The repository's own scratch path stays its choice.
    let own = Self.request(area, "swift build --scratch-path .build/ci", in: "/work/a")
    #expect(AreaBuildPlacement.checkout(own, kind: .swiftpm, layout: Self.slot) == own)
    #expect(
      XcodeDerivedData.buildDirectories(own, kind: .swiftpm, layout: Self.slot)
        == ["/work/a/.build"])
    // Xcode keys a build by the project's path: a shared DerivedData rebuilt every target on each
    // switch of checkout, so an xcode area keeps the slot's own.
    let starter = try Self.area("InterviewStarter")
    let xcode = Self.request(starter, try #require(starter.build), in: "/work/repo-spec.slot-3")
    #expect(
      AreaBuildPlacement.checkout(xcode, kind: .xcode, layout: Self.slot)
        == XcodeDerivedData.request(xcode, layout: Self.slot))
  }
}

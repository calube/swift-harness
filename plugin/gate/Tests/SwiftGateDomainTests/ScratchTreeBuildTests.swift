import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("scratch-tree builds in shared per-area caches")
struct ScratchTreeBuildTests {
  private static let common = URL(filePath: "/clone/.git", directoryHint: .isDirectory)
  private static let linked = BrownfieldStateLayout(
    commonDir: common,
    gitDir: URL(filePath: "/clone/.git/worktrees/task", directoryHint: .isDirectory))
  private static let main = BrownfieldStateLayout(commonDir: common, gitDir: common)
  private static let shared = "/clone/.git/swift-harness/caches/swiftpm-scratch/AppFeature"
  private static let slotProve = "/clone/.git/worktrees/task/swift-harness/derived-data/prove/AppFeature"

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

  private static func request(_ area: BrownfieldArea, _ command: String) -> AreaCommandRequest {
    AreaCommandRequest(
      area: area.name, step: .testFiles, command: command, workingDirectory: "/scratch/tree",
      deadline: .seconds(600), environment: [:], junitPath: nil)
  }

  @Test(
    "the trial's swiftpm build, test and test_files commands build, in a linked worktree's scratch tree, in that worktree's own prove scratch path, which they take turns in and time, and in the main checkout's in the shared path — catches the send-money trial's 3 concurrent slices taking turns on AppFeature's 1 shared scratch path, proving in 106-323 s against 19-25 s alone"
  )
  func swiftPMCommandsGetTheWorktreesProvePath() throws {
    let area = try Self.area("AppFeature")
    #expect(ScratchTreeBuild.swiftPMScratchPath(area: area.name, layout: Self.linked) == Self.shared)
    #expect(ScratchTreeBuild.proveScratchPath(area: area.name, layout: Self.linked) == Self.slotProve)
    #expect(ScratchTreeBuild.proveScratchPath(area: area.name, layout: Self.main) == Self.shared)
    let commands = try [area.build, area.test, area.testFiles].map { try #require($0) }
    for (layout, path) in [(Self.linked, Self.slotProve), (Self.main, Self.shared)] {
      for command in commands {
        let waits = BuildLockWaits()
        let request = ScratchTreeBuild.request(
          Self.request(area, command), kind: area.kind, layout: layout, waits: waits)
        let rest = try #require(command.split(separator: " ", maxSplits: 2).last)
        let verb = command.split(separator: " ")[1]
        #expect(
          request.command
            == "swift \(verb) --scratch-path '\(path)'" + (rest == verb ? "" : " \(rest)"),
          "\(command)")
        #expect(request.workingDirectory == "/scratch/tree")
        #expect(request.buildLock == BuildDirectoryLock(directory: path, waits: waits))
      }
    }
    let untimed = ScratchTreeBuild.request(
      Self.request(area, try #require(area.build)), kind: area.kind, layout: Self.linked)
    #expect(untimed.buildLock == nil)
  }

  @Test(
    "a command that names its own scratch or build path, runs no swift build or test, or spells swift where the insertion can't place it is left alone — catches an override of the repository's choice or a flag passed to another tool",
    arguments: [
      "swift test --scratch-path .build/ci", "swift build --build-path=.build/ci", "npm test",
      "echo swift test", "swift package resolve", "/usr/bin/swift test",
    ])
  func leftAlone(command: String) {
    #expect(ScratchTreeBuild.swiftPMCommand(command, scratchPath: "/p") == command)
  }

  @Test(
    "each swift build or test of a compound command gets the path — catches only the first of 2 builds placed"
  )
  func compound() {
    #expect(
      ScratchTreeBuild.swiftPMCommand(
        "swift build && swift test --filter 'A|B'", scratchPath: "/p q")
        == "swift build --scratch-path '/p q' && swift test --scratch-path '/p q' --filter 'A|B'")
  }

  @Test(
    "a scratch tree's xcode command builds in the worktree's prove DerivedData and a swiftpm one in the worktree's prove scratch path, and those are the folders a step reads as warm — catches a baseline rerun writing gigabytes into Xcode's global DerivedData and every prove step labelled none"
  )
  func buildDirectories() throws {
    let starter = try Self.area("InterviewStarter")
    let feature = try Self.area("AppFeature")
    let prove = "/clone/.git/worktrees/task/swift-harness/derived-data/prove/InterviewStarter"
    #expect(
      ScratchTreeBuild.buildDirectories(area: starter, layout: Self.linked) == ["\(prove)/Build"])
    #expect(
      ScratchTreeBuild.buildDirectories(area: feature, layout: Self.linked) == [Self.slotProve])
    #expect(ScratchTreeBuild.buildDirectories(area: feature, layout: Self.main) == [Self.shared])
    let xcode = ScratchTreeBuild.request(
      Self.request(starter, try #require(starter.build)), kind: .xcode, layout: Self.linked)
    #expect(xcode.command.hasPrefix("xcodebuild -derivedDataPath '\(prove)' "))
  }
}

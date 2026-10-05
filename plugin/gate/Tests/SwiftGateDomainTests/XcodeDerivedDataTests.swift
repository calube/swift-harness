import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("per-worktree DerivedData for xcode area commands")
struct XcodeDerivedDataTests {
  private static let common = URL(filePath: "/clone/.git", directoryHint: .isDirectory)
  private static let linked = BrownfieldStateLayout(
    commonDir: common,
    gitDir: URL(filePath: "/clone/.git/worktrees/task", directoryHint: .isDirectory))
  private static let main = BrownfieldStateLayout(commonDir: common, gitDir: common)
  private static let seed = "/clone/.git/swift-harness/caches/derived-data/Aidoku"
  private static let own = "/clone/.git/worktrees/task/swift-harness/derived-data/areas/Aidoku"

  /// The `test` and `build` commands discovery wrote for the third brownfield iOS trial.
  private static func trialCommand(_ key: String) throws -> String {
    let config = try Fixture.text("BrownfieldTrial/aidoku-validation-config.toml")
    let prefix = "\(key) = \""
    return try #require(
      config.split(separator: "\n").first { $0.hasPrefix(prefix) }
        .map { String($0.dropFirst(prefix.count).dropLast()) })
  }

  private static func request(_ command: String) -> AreaCommandRequest {
    AreaCommandRequest(
      area: "Aidoku", step: .build, command: command, workingDirectory: "/work/task",
      deadline: .seconds(600), environment: [:], junitPath: nil)
  }

  @Test(
    "a linked worktree builds in its own folder under its git dir and the main checkout in the area's seed — catches every worktree in Xcode's path-keyed default DerivedData, or 2 worktrees sharing 1 folder"
  )
  func paths() {
    #expect(XcodeDerivedData.path(area: "Aidoku", layout: Self.linked) == Self.own)
    #expect(XcodeDerivedData.path(area: "Aidoku", layout: Self.main) == Self.seed)
  }

  @Test(
    "the trial's build and test commands get the worktree's DerivedData right after xcodebuild — catches a task worktree's first slice compiling in a cold default DerivedData",
    arguments: ["build", "test"])
  func trialCommandsGetThePath(key: String) throws {
    let command = try Self.trialCommand(key)
    let rest = try #require(command.split(separator: " ", maxSplits: 1).last)

    #expect(
      XcodeDerivedData.command(command, derivedDataPath: "/dd/it's")
        == "xcodebuild -derivedDataPath '/dd/it'\\''s' \(rest)")
  }

  @Test(
    "a command that names its own DerivedData, runs no xcodebuild, or names xcodebuild only as an argument is left alone — catches an override of the repository's choice or a flag passed to another tool",
    arguments: [
      "xcodebuild test -scheme App -derivedDataPath build/dd",
      "xcodebuild -derivedDataPath=build/dd test -scheme App",
      "npm test",
      "echo xcodebuild",
      "/usr/bin/xcodebuild test -scheme App",
    ])
  func leftAlone(command: String) {
    #expect(XcodeDerivedData.command(command, derivedDataPath: "/dd") == command)
  }

  @Test(
    "each xcodebuild in a pipeline or a list gets the path, and a tool it pipes into doesn't — catches the flag appended to xcpretty"
  )
  func pipeline() {
    #expect(
      XcodeDerivedData.command(
        "set -o pipefail && xcodebuild build -scheme App | xcpretty && xcodebuild test -scheme App",
        derivedDataPath: "/dd")
        == "set -o pipefail && xcodebuild -derivedDataPath '/dd' build -scheme App | xcpretty && "
        + "xcodebuild -derivedDataPath '/dd' test -scheme App")
  }

  @Test(
    "a linked worktree's request builds in its own folder seeded from the area's seed, and the main checkout's builds in the seed with nothing to copy — catches a worktree starting cold beside a warm seed"
  )
  func requests() throws {
    let build = try Self.trialCommand("build")

    let linked = XcodeDerivedData.request(Self.request(build), layout: Self.linked)
    #expect(linked.command.contains("xcodebuild -derivedDataPath '\(Self.own)' build "))
    #expect(linked.derivedDataSeed == DerivedDataSeedCopy(seed: Self.seed, destination: Self.own))
    #expect(linked.workingDirectory == "/work/task")

    let main = XcodeDerivedData.request(Self.request(build), layout: Self.main)
    #expect(main.command.contains("xcodebuild -derivedDataPath '\(Self.seed)' build "))
    #expect(main.derivedDataSeed == nil)
  }

  @Test(
    "a request whose command runs no xcodebuild gets no seed — catches a node area's worktree cloning a DerivedData it never reads"
  )
  func otherToolsGetNoSeed() {
    let request = XcodeDerivedData.request(Self.request("npm test"), layout: Self.linked)
    #expect(request == Self.request("npm test"))
  }
}

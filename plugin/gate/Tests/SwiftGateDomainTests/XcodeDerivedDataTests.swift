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

  @Test(
    "prove's run of the trial's test command in a scratch tree builds in the worktree's prove DerivedData for the area, seeded from the area's seed, in a linked worktree and the main checkout — catches prove building cold in Xcode's global DerivedData, 1.3 GB per scratch path, or over the worktree's own build"
  )
  func proveRequests() throws {
    let test = try Self.trialCommand("test")
    let prove = "/clone/.git/worktrees/task/swift-harness/derived-data/prove/Aidoku"
    let mainProve = "/clone/.git/swift-harness/derived-data/prove/Aidoku"

    let linked = XcodeDerivedData.proveRequest(Self.request(test), layout: Self.linked)
    #expect(linked.command.hasPrefix("xcodebuild -derivedDataPath '\(prove)' test "))
    #expect(linked.derivedDataSeed == DerivedDataSeedCopy(seed: Self.seed, destination: prove))

    let main = XcodeDerivedData.proveRequest(Self.request(test), layout: Self.main)
    #expect(main.command.hasPrefix("xcodebuild -derivedDataPath '\(mainProve)' test "))
    #expect(main.derivedDataSeed == DerivedDataSeedCopy(seed: Self.seed, destination: mainProve))

    #expect(
      XcodeDerivedData.proveRequest(Self.request("swift test"), layout: Self.linked)
        == Self.request("swift test"))
  }

  @Test(
    "an xcode step's build directory is the Build folder of the DerivedData its command was given, a swiftpm step's is its area's .build, and any other step has none — catches every gate step labelled derivedData none, 73-133 s xcode builds included"
  )
  func buildDirectories() throws {
    let build = XcodeDerivedData.request(
      Self.request(try Self.trialCommand("build")), layout: Self.linked)
    #expect(
      XcodeDerivedData.buildDirectories(build, kind: .xcode, layout: Self.linked)
        == ["\(Self.own)/Build"])
    let prove = XcodeDerivedData.proveRequest(
      Self.request(try Self.trialCommand("test")), layout: Self.linked)
    #expect(
      XcodeDerivedData.buildDirectories(prove, kind: .xcode, layout: Self.linked)
        == ["/clone/.git/worktrees/task/swift-harness/derived-data/prove/Aidoku/Build"])
    #expect(
      XcodeDerivedData.buildDirectories(
        Self.request("swift build"), kind: .swiftpm, layout: Self.linked)
        == ["/work/task/.build"])
    #expect(
      XcodeDerivedData.buildDirectories(Self.request("npm test"), kind: .node, layout: Self.linked)
        == [])
    #expect(
      XcodeDerivedData.buildDirectories(
        Self.request("xcodebuild test -scheme App -derivedDataPath build/dd"), kind: .xcode,
        layout: Self.linked) == [],
      "a DerivedData the repository names is one the harness doesn't track")
  }
}

import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("an xcode test command's named simulator, pointed at a leased clone")
struct XcodeTestDestinationTests {
  /// A command discovery wrote for a brownfield iOS trial.
  private static func trialCommand(_ key: String) throws -> String {
    let config = try Fixture.text("BrownfieldTrial/aidoku-validation-config.toml")
    let prefix = "\(key) = \""
    return try #require(
      config.split(separator: "\n").first { $0.hasPrefix(prefix) }
        .map { String($0.dropFirst(prefix.count).dropLast()) })
  }

  @Test(
    "discovery's test command names the shared `iPhone 17` and is rewritten to `-destination 'id=<udid>'` with every other word kept — catches a test run left on the 1 device every session shares"
  )
  func discoveredTestCommandIsLeased() throws {
    let test = try Self.trialCommand("test")

    #expect(
      XcodeTestDestination.simulator(in: test)
        == XcodeTestDestination(device: "iPhone 17", os: nil))
    #expect(
      XcodeTestDestination.leased(test, udid: "CLONE-UDID")
        == "xcodebuild test -project Aidoku.xcodeproj -scheme Aidoku -destination 'id=CLONE-UDID' "
        + "-skipMacroValidation -skipPackagePluginValidation")
  }

  @Test(
    "a `test:` row's command, with `-only-testing:` and `-resultBundlePath` after it, keeps both once leased — catches a rewrite that drops the narrowing and runs every test"
  )
  func narrowedCommandKeepsItsTail() throws {
    let test =
      try Self.trialCommand("test")
      + " -only-testing:'AidokuUITests/MainFlowUITests' -resultBundlePath '/tmp/run/qa/01.xcresult'"

    #expect(
      XcodeTestDestination.leased(test, udid: "CLONE-UDID")
        == "xcodebuild test -project Aidoku.xcodeproj -scheme Aidoku -destination 'id=CLONE-UDID' "
        + "-skipMacroValidation -skipPackagePluginValidation "
        + "-only-testing:'AidokuUITests/MainFlowUITests' -resultBundlePath '/tmp/run/qa/01.xcresult'")
  }

  @Test(
    "an `OS=` version is read with the device, and `OS=latest` reads as no version — catches a clone made on a runtime the command never asked for"
  )
  func readsTheOSVersion() {
    #expect(
      XcodeTestDestination.simulator(
        in: "xcodebuild test -scheme App -destination \"platform=iOS Simulator,name=iPhone 17,OS=26.2\"")
        == XcodeTestDestination(device: "iPhone 17", os: "26.2"))
    #expect(
      XcodeTestDestination.simulator(
        in: "xcodebuild test -scheme App -destination 'platform=iOS Simulator,OS=latest,name=iPhone 17'")
        == XcodeTestDestination(device: "iPhone 17", os: nil))
  }

  @Test(
    "discovery's generic build, its build-for-testing, a destination by id and a command that isn't xcodebuild name no simulator to lease — catches a lease taken for a run that launches nothing"
  )
  func runsNothingOnANamedSimulator() throws {
    let build = try Self.trialCommand("build")
    let buildForTesting = try #require(
      XcodeBuildForTesting.command(fromTest: try Self.trialCommand("test")))

    for command in [
      build, buildForTesting,
      "xcodebuild test -scheme App -destination 'id=ABCD-1234'",
      "xcodebuild test -scheme App -destination 'platform=macOS'",
      "swift test --filter 'name=iPhone 17'",
    ] {
      #expect(XcodeTestDestination.simulator(in: command) == nil, "\(command)")
      #expect(XcodeTestDestination.leased(command, udid: "CLONE-UDID") == nil, "\(command)")
    }
    // The same area's test command does name 1, so the reads above are not a reader that finds
    // nothing anywhere.
    #expect(XcodeTestDestination.simulator(in: try Self.trialCommand("test")) != nil)
  }

  @Test(
    "a destination spelt with backslash escapes, which the text can't be matched against, names no simulator to lease and is left alone — catches a command broken by the rewrite, or a clone leased for a command still run as written"
  )
  func unmatchableSpellingIsLeftAlone() {
    let escaped = #"xcodebuild test -scheme App -destination platform=iOS\ Simulator,name=iPhone\ 17"#
    let quoted = "xcodebuild test -scheme App -destination 'platform=iOS Simulator,name=iPhone 17'"

    #expect(XcodeTestDestination.simulator(in: escaped) == nil)
    #expect(XcodeTestDestination.leased(escaped, udid: "CLONE-UDID") == nil)
    #expect(
      XcodeTestDestination.leased(quoted, udid: "CLONE-UDID")
        == "xcodebuild test -scheme App -destination 'id=CLONE-UDID'")
  }
}

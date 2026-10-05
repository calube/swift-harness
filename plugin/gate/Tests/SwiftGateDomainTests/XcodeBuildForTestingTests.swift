import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("build-for-testing for a build-only xcode slice")
struct XcodeBuildForTestingTests {
  /// The `test` and `build` commands discovery wrote for the third brownfield iOS trial.
  private static func trialCommand(_ key: String) throws -> String {
    let config = try Fixture.text("BrownfieldTrial/aidoku-validation-config.toml")
    let prefix = "\(key) = \""
    return try #require(
      config.split(separator: "\n").first { $0.hasPrefix(prefix) }
        .map { String($0.dropFirst(prefix.count).dropLast()) })
  }

  private static func area(kind: AreaKind, test: String?, build: String?) -> BrownfieldArea {
    BrownfieldArea(
      name: "Aidoku", root: ".", language: .swift, kind: kind, test: test, testFiles: nil,
      lint: nil, build: build, e2e: nil, testGlobs: ["**/AidokuTests/**/*.swift"], packs: [],
      xcode: kind == .xcode
        ? XcodeAreaConfig(
          workspace: nil, project: "Aidoku.xcodeproj", inclusion: .synchronized, manifest: nil,
          schemes: ["Aidoku"])
        : nil)
  }

  @Test(
    "the trial's discovered test command becomes build-for-testing on the same scheme and simulator destination — catches a build-only slice that compiles the app but never its test target"
  )
  func trialTestCommandBuildsForTesting() throws {
    let test = try Self.trialCommand("test")

    #expect(
      XcodeBuildForTesting.command(fromTest: test)
        == "xcodebuild build-for-testing -project Aidoku.xcodeproj -scheme Aidoku -destination "
        + "'platform=iOS Simulator,name=iPhone 17' -skipMacroValidation "
        + "-skipPackagePluginValidation")
  }

  @Test(
    "an action written after the options is the one replaced, and a quoted destination is kept whole — catches a rewrite that only knows the discovered word order"
  )
  func trailingActionIsReplaced() {
    #expect(
      XcodeBuildForTesting.command(
        fromTest:
          "xcodebuild -scheme SampleApp -destination 'platform=iOS Simulator,name=iPhone 17' test")
        == "xcodebuild -scheme SampleApp -destination 'platform=iOS Simulator,name=iPhone 17' "
        + "build-for-testing")
  }

  @Test(
    "a command it can't rewrite safely comes back nil, so the slice keeps its plain build — catches a rewrite that runs a test-only option or a chained script as a build"
  )
  func unsafeCommandsAreLeftAlone() {
    let unsafe = [
      "xcodebuild test -scheme App -only-testing:AppTests/LoadTests",
      "xcodebuild test -scheme App -test-iterations 3",
      "xcodebuild test -scheme App {tests}",
      "xcodebuild build -scheme App",
      "xcodebuild test -scheme App && echo done",
      "make test",
      "test-all",
    ]
    for command in unsafe {
      #expect(XcodeBuildForTesting.command(fromTest: command) == nil, "\(command)")
    }
  }

  @Test(
    "an xcode area's build becomes its build-for-testing and every other field stays; a non-xcode area gets none — catches a swap that loses the area's other commands or reaches other kinds"
  )
  func areaSwapsOnlyItsBuild() throws {
    let xcode = Self.area(
      kind: .xcode, test: try Self.trialCommand("test"), build: try Self.trialCommand("build"))

    let swapped = try #require(XcodeBuildForTesting.area(xcode))

    #expect(swapped.build == XcodeBuildForTesting.command(fromTest: try Self.trialCommand("test")))
    #expect(swapped.test == xcode.test)
    #expect(swapped.xcode == xcode.xcode)
    #expect(swapped.name == xcode.name && swapped.root == xcode.root)
    #expect(
      XcodeBuildForTesting.area(
        Self.area(kind: .swiftpm, test: try Self.trialCommand("test"), build: "swift build")) == nil
    )
    #expect(XcodeBuildForTesting.area(Self.area(kind: .xcode, test: nil, build: "x")) == nil)
  }
}

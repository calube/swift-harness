import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// A Bash call that ran `swift build`, as the trial's transcript recorded it.
private struct CapturedCall: Decodable {
  let command: String
}

@Suite("Bash guard on a raw swift build in a brownfield clone")
struct RawSwiftBuildGuardTests {
  static let layout = BrownfieldStateLayout(
    commonDir: URL(filePath: "/CLONE/.git", directoryHint: .isDirectory),
    gitDir: URL(filePath: "/CLONE/.git/worktrees/repo-spec", directoryHint: .isDirectory))

  @Test(
    "each of the trial orchestrator's 4 contract-phase swift builds, which built cold in each package's own .build for 33 s and 177 s, is denied as guard.raw-swift-build naming the slice gate, test-only and the clone's shared scratch path — catches a build that skips the warm scratch path the slice gate then builds in 9 s"
  )
  func capturedContractBuildsDenied() throws {
    let calls = try JSONDecoder().decode(
      [CapturedCall].self, from: Fixture.data("Hooks/price-tracker-5-raw-swift-build-bash.json"))
    try #require(calls.count == 4)

    for call in calls {
      let violation = try #require(
        BrownfieldBuildGuard.evaluate(call.command, layout: Self.layout),
        "\(call.command.suffix(120))")
      #expect(violation.ruleID == BrownfieldBuildGuard.rawSwiftBuildRuleID)
      #expect(violation.reason.contains("--tier slice"), "\(violation.reason)")
      #expect(violation.reason.contains("test-only"), "\(violation.reason)")
      #expect(
        violation.reason.contains(
          "--scratch-path /CLONE/.git/swift-harness/caches/swiftpm-scratch/"),
        "\(violation.reason)")
    }
  }

  @Test(
    "a swift build or test that names its scratch or build path, swift package and swift --version, and swift build text inside a heredoc pass — catches the guard denying a build that already shares the warm path, or a tool that builds nothing",
    arguments: [
      "cd Packages/APIClient && swift build --scratch-path /CLONE/.git/swift-harness/caches/swiftpm-scratch/APIClient",
      "swift test --scratch-path=/s/AppFeature --filter AppCoreTests",
      "swift build --build-path .build-own",
      "swift package resolve",
      "swift --version",
      "cat > notes.md <<'EOF'\nrun swift build first\nEOF",
    ])
  func sharedOrNonBuildingCommandsPass(_ command: String) {
    #expect(BrownfieldBuildGuard.evaluate(command, layout: Self.layout) == nil, "\(command)")
  }

  @Test(
    "a swift test, a swift build behind && or a pipe, and a swift build through env are denied — catches a spelling that still builds cold",
    arguments: [
      "cd Packages/AppFeature && swift test --filter AppCoreTests",
      "git status && swift build 2>&1 | tail -3",
      "env NSUnbufferedIO=YES swift build -c debug",
    ])
  func otherSpellingsDenied(_ command: String) {
    #expect(
      BrownfieldBuildGuard.evaluate(command, layout: Self.layout)?.ruleID
        == BrownfieldBuildGuard.rawSwiftBuildRuleID, "\(command)")
  }
}

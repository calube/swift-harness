import SwiftGateDomain
import Testing

@Suite("Bash guard")
struct BashGuardTests {
  @Test(
    "raw xcodebuild is denied wherever it sits in the command line — catches builds bypassing per-worktree DerivedData and the sim lock",
    arguments: [
      "xcodebuild test -scheme App",
      "cd App && xcodebuild -scheme App build",
      "DEVELOPER_DIR=/Applications/Xcode.app xcodebuild build",
      "xcrun xcodebuild test",
      "/usr/bin/xcodebuild archive",
      "echo $(xcodebuild build)",
      "bash -c 'xcodebuild test -scheme App'",
      "time env FOO=1 xcodebuild -project A.xcodeproj -list build",
      "xcodebuild -resolvePackageDependencies",
    ])
  func rawXcodebuildDenied(command: String) {
    #expect(BashGuard.evaluate(command)?.ruleID == BashGuard.rawXcodebuildRuleID)
  }

  @Test(
    "read-only queries, per-device simctl, worktree DerivedData and look-alikes pass — catches the guards blocking everyday commands",
    arguments: [
      "xcodebuild -version",
      "xcodebuild -showsdks",
      "xcodebuild -project App.xcodeproj -list",
      "echo 'xcodebuild test is blocked'",
      "grep -rn xcodebuild docs",
      "git log --grep xcodebuild",
      "xcrun simctl delete 5D2C3F1E-0000-4000-8000-000000000001",
      "xcrun simctl shutdown all",
      "xcrun simctl list devices",
      "rm -rf .harness/DerivedData",
      "rm -rf examples/SampleApp/DerivedData",
      "ls ~/Library/Developer/Xcode/DerivedData",
    ])
  func harmlessCommandsPass(command: String) {
    #expect(BashGuard.evaluate(command) == nil)
  }

  @Test(
    "erasing or deleting every simulator is denied — catches one session wiping the simulators other sessions are using",
    arguments: [
      "xcrun simctl erase all", "xcrun simctl delete all", "simctl delete all",
      "xcrun simctl shutdown all; xcrun simctl erase all",
    ])
  func simctlAllDenied(command: String) {
    #expect(BashGuard.evaluate(command)?.ruleID == BashGuard.simctlAllRuleID)
  }

  @Test(
    "turning snapshot recording on is denied — catches references re-recorded to match a regression",
    arguments: [
      "SNAPSHOT_TESTING_RECORD=all swift test",
      "export SNAPSHOT_TESTING_RECORD=failed",
      "env TEST_RUNNER_SNAPSHOT_TESTING_RECORD=missing swift test",
      "swiftgate check --tier fast && SNAPSHOT_TESTING_RECORD=\"all\" swift test",
    ])
  func snapshotRecordDenied(command: String) {
    #expect(BashGuard.evaluate(command)?.ruleID == BashGuard.snapshotRecordRuleID)
  }

  @Test("recording explicitly off passes — catches the guard blocking the safe setting")
  func snapshotRecordNeverPasses() {
    #expect(BashGuard.evaluate("SNAPSHOT_TESTING_RECORD=never swift test") == nil)
  }

  @Test(
    "deleting the global DerivedData is denied — catches one session destroying every other session's build cache",
    arguments: [
      "rm -rf ~/Library/Developer/Xcode/DerivedData",
      "rm -rf \"$HOME/Library/Developer/Xcode/DerivedData/\"*",
      "rm -rf ~/Library/Developer/Xcode/DerivedData/App-abcdef",
      "rm -rf ~/Library/Developer/Xcode",
      "sudo rm -r /Users/me/Library/Developer/Xcode/DerivedData",
    ])
  func globalDerivedDataDeletionDenied(command: String) {
    #expect(BashGuard.evaluate(command)?.ruleID == BashGuard.globalDerivedDataRuleID)
  }

  @Test(
    "git commit is recognised through options and chains — catches the commit comment pass never running",
    arguments: [
      ("git commit -m 'x'", true), ("git -C sub commit --amend", true),
      ("git add -A && git commit -m x", true), ("git commit-tree abc", false),
      ("git log --grep commit", false), ("echo git commit", false),
    ])
  func gitCommitRecognised(command: String, expected: Bool) {
    #expect(BashGuard.isGitCommit(command) == expected)
  }
}

@Suite("Edit guard")
struct EditGuardTests {
  @Test(
    "hand edits to recorded or generated artifacts are denied — catches a snapshot, lockfile or result bundle edited to make a gate pass",
    arguments: [
      ("/r/Tests/FooTests/__Snapshots__/FooTests/view.1.png", EditGuard.snapshotReferenceRuleID),
      ("/r/Packages/Feed/Package.resolved", EditGuard.packageResolvedRuleID),
      (
        "/r/App.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
        EditGuard.packageResolvedRuleID
      ),
      ("/r/.harness/runs/r1/t2.xcresult/Info.plist", EditGuard.xcresultRuleID),
    ])
  func artifactsDenied(path: String, rule: String) {
    #expect(EditGuard.evaluate(path: path)?.ruleID == rule)
  }

  @Test("ordinary source edits pass — catches the guard blocking normal work")
  func sourcePasses() {
    #expect(
      EditGuard.evaluate(path: "/r/Packages/Feed/Sources/FeedCore/Feed.swift") == nil)
    #expect(EditGuard.evaluate(path: "/r/docs/Package.resolved.md") == nil)
  }

  @Test(
    "the orchestrator is the env marker or the lock naming this session, never a subagent — catches workers inheriting orchestrator rights"
  )
  func orchestratorMarker() {
    let session = "s-1"
    #expect(
      OrchestratorMarker.isOrchestrator(
        environmentValue: "1", lockContents: nil, sessionID: session, agentID: nil))
    #expect(
      OrchestratorMarker.isOrchestrator(
        environmentValue: nil, lockContents: "s-1\n", sessionID: session, agentID: nil))
    #expect(
      !OrchestratorMarker.isOrchestrator(
        environmentValue: nil, lockContents: "other", sessionID: session, agentID: nil))
    #expect(
      !OrchestratorMarker.isOrchestrator(
        environmentValue: "1", lockContents: "s-1", sessionID: session, agentID: "worker"))
    #expect(
      !OrchestratorMarker.isOrchestrator(
        environmentValue: "0", lockContents: nil, sessionID: session, agentID: nil))
  }
}

import Foundation

/// Why a guard refused a tool call. `reason` is shown to Claude as the denial.
public struct GuardViolation: Sendable, Equatable {
  public let ruleID: String
  public let reason: String

  public init(ruleID: String, reason: String) {
    self.ruleID = ruleID
    self.reason = reason
  }
}

/// PreToolUse guards on Bash commands (spec §8): actions that bypass swiftgate or damage state
/// other sessions on the machine share.
public enum BashGuard {
  public static let rawXcodebuildRuleID = "guard.raw-xcodebuild"
  public static let simctlAllRuleID = "guard.simctl-all"
  public static let snapshotRecordRuleID = "guard.snapshot-record"
  public static let globalDerivedDataRuleID = "guard.global-derived-data"

  public static func evaluate(_ command: String) -> GuardViolation? {
    for simple in ShellSyntax.simpleCommands(in: command) {
      if let violation = evaluate(simple) { return violation }
    }
    return nil
  }

  /// Whether the command line runs `git commit` (in any simple command of it).
  public static func isGitCommit(_ command: String) -> Bool {
    ShellSyntax.simpleCommands(in: command).contains { simple in
      guard simple.name == "git" else { return false }
      return gitSubcommand(simple.arguments) == "commit"
    }
  }

  private static func evaluate(_ command: SimpleCommand) -> GuardViolation? {
    if let violation = snapshotRecording(command) { return violation }
    switch command.name {
    case "xcodebuild" where !isReadOnlyXcodebuild(command.arguments):
      return GuardViolation(
        ruleID: rawXcodebuildRuleID,
        reason:
          "raw xcodebuild bypasses swiftgate's per-worktree DerivedData, simulator lock and "
          + "evidence rules. Use `swiftgate check --tier fast|push|ready` (or `swiftgate test "
          + "--tier t2|t3` for simulator tiers). Read-only queries such as `xcodebuild -list` "
          + "are allowed.")
    case "simctl"
    where ["erase", "delete"].contains(command.arguments.first)
      && command.arguments.dropFirst().contains("all"):
      return GuardViolation(
        ruleID: simctlAllRuleID,
        reason:
          "`simctl \(command.arguments[0]) all` destroys simulators other sessions on this Mac "
          + "are using. swiftgate clones and deletes its own devices; delete one by UDID if you "
          + "must.")
    case let name?
    where deletes(name, command.arguments) && command.arguments.contains(where: isGlobalDerivedData):
      return derivedDataViolation
    default:
      return nil
    }
  }

  private static func deletes(_ name: String, _ arguments: [String]) -> Bool {
    ["rm", "rmdir", "unlink", "trash", "srm"].contains(name)
      || (name == "find" && arguments.contains("-delete"))
  }

  private static let derivedDataViolation = GuardViolation(
    ruleID: globalDerivedDataRuleID,
    reason:
      "the global DerivedData is shared by every session and Xcode on this Mac. swiftgate builds "
      + "into per-worktree DerivedData under .harness/; prune it with `swiftgate gc`.")

  private static let recordVariables: Set<String> = [
    "SNAPSHOT_TESTING_RECORD", "TEST_RUNNER_SNAPSHOT_TESTING_RECORD",
  ]

  /// Environment assignments reach a test run through a leading `NAME=value`, `env`, `export`,
  /// or an xcodebuild/swift argument.
  private static func snapshotRecording(_ command: SimpleCommand) -> GuardViolation? {
    let carriers: Set<String> = ["export", "declare", "typeset", "xcodebuild", "swift", "setenv"]
    let candidates =
      command.assignments + (carriers.contains(command.name ?? "") ? command.arguments : [])
    for word in candidates {
      guard let equals = word.firstIndex(of: "=") else { continue }
      let name = String(word[..<equals])
      let value = word[word.index(after: equals)...].lowercased()
      if recordVariables.contains(name), !value.isEmpty, value != "never" {
        return GuardViolation(
          ruleID: snapshotRecordRuleID,
          reason:
            "\(name)=\(value) re-records snapshot references, so a visual regression becomes "
            + "the new reference. Re-record deliberately with `swiftgate snapshots record`.")
      }
    }
    return nil
  }

  private static let readOnlyXcodebuildFlags: Set<String> = [
    "-version", "-showsdks", "-list", "-showBuildSettings", "-showdestinations",
    "-showTestPlans", "-help", "-usage", "-checkFirstLaunchStatus", "-showComponent",
  ]
  private static let xcodebuildActions: Set<String> = [
    "build", "build-for-testing", "analyze", "archive", "test", "test-without-building",
    "install", "installsrc", "clean", "docbuild", "-resolvePackageDependencies",
    "-exportArchive", "-exportLocalizations", "-importLocalizations", "-runFirstLaunch",
    "-downloadPlatform", "-downloadAllPlatforms",
  ]

  private static func isReadOnlyXcodebuild(_ arguments: [String]) -> Bool {
    arguments.contains(where: readOnlyXcodebuildFlags.contains)
      && !arguments.contains(where: xcodebuildActions.contains)
  }

  private static func isGlobalDerivedData(_ argument: String) -> Bool {
    var path = Substring(argument)
    while path.hasSuffix("/") || path.hasSuffix("*") { path = path.dropLast() }
    return path.contains("Library/Developer/Xcode/DerivedData")
      || path.hasSuffix("Library/Developer/Xcode") || path.hasSuffix("Library/Developer")
  }

  private static let gitOptionsWithValues: Set<String> = [
    "-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--config-env",
  ]

  private static func gitSubcommand(_ arguments: [String]) -> String? {
    var rest = arguments[...]
    while let option = rest.first, option.hasPrefix("-") {
      rest = rest.dropFirst()
      if gitOptionsWithValues.contains(option) { rest = rest.dropFirst() }
    }
    return rest.first
  }
}

/// PreToolUse guards on Edit/Write paths (spec §8): recorded or generated artifacts, and plan
/// state only the orchestrating session may write.
public enum EditGuard {
  public static let snapshotReferenceRuleID = "guard.snapshot-reference"
  public static let packageResolvedRuleID = "guard.package-resolved"
  public static let xcresultRuleID = "guard.xcresult"
  public static let planStateRuleID = "guard.plan-state"

  public static func evaluate(path: String, isOrchestrator: Bool) -> GuardViolation? {
    let components = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
    guard let file = components.last else { return nil }
    if components.contains("__Snapshots__") {
      return GuardViolation(
        ruleID: snapshotReferenceRuleID,
        reason:
          "snapshot references are recorded by the test run, never hand-edited: an edited "
          + "reference hides the regression it exists to catch. Use `swiftgate snapshots record`.")
    }
    if file == "Package.resolved" {
      return GuardViolation(
        ruleID: packageResolvedRuleID,
        reason:
          "Package.resolved is written by SwiftPM. Change Package.swift and run "
          + "`swift package resolve` (or `update`) instead.")
    }
    if components.contains(where: { $0.hasSuffix(".xcresult") }) {
      return GuardViolation(
        ruleID: xcresultRuleID,
        reason: "result bundles are test evidence; editing one forges it. Re-run the tests.")
    }
    if !isOrchestrator, isPlanState(components) {
      return GuardViolation(
        ruleID: planStateRuleID,
        reason:
          "plan ledgers and .harness/plans/index.json are written only by the orchestrating "
          + "session. Report progress to the orchestrator instead. The orchestrator is marked by "
          + "SWIFT_HARNESS_ORCHESTRATOR=1 or .harness/orchestrator.lock holding its session id.")
    }
    return nil
  }

  private static func isPlanState(_ components: [String]) -> Bool {
    for index in components.indices.dropLast()
    where components[index] == ".harness" && components[index + 1] == "plans" {
      let inside = components[(index + 2)...]
      if inside.last == "ledger.json", inside.count >= 2 { return true }
      if Array(inside) == ["index.json"] { return true }
    }
    return false
  }
}

/// Who may write plan state (spec §4.2: orchestrator-only writes). Subagents never qualify, even
/// in an orchestrator's session: they are the workers the rule exists for.
public enum OrchestratorMarker {
  public static let environmentVariable = "SWIFT_HARNESS_ORCHESTRATOR"
  /// Repository-relative; holds the orchestrating session's id.
  public static let lockFile = ".harness/orchestrator.lock"

  public static func isOrchestrator(
    environmentValue: String?, lockContents: String?, sessionID: String, agentID: String?
  ) -> Bool {
    guard agentID == nil else { return false }
    if environmentValue?.trimmingCharacters(in: .whitespacesAndNewlines) == "1" { return true }
    guard !sessionID.isEmpty, let lockContents else { return false }
    return lockContents.trimmingCharacters(in: .whitespacesAndNewlines) == sessionID
  }
}

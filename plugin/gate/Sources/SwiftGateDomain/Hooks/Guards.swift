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

/// PreToolUse guards on Edit/Write paths (spec §8): recorded or generated artifacts. Plan state
/// lives in the git common dir and is ``PlanStateGuard``'s; `planStateRuleID` names its denials.
public enum EditGuard {
  public static let snapshotReferenceRuleID = "guard.snapshot-reference"
  public static let packageResolvedRuleID = "guard.package-resolved"
  public static let xcresultRuleID = "guard.xcresult"
  public static let planStateRuleID = "guard.plan-state"

  public static func evaluate(path: String) -> GuardViolation? {
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
    return nil
  }
}

/// Who may write plan state (spec §4.2: orchestrator-only writes). Subagents never qualify, even
/// in an orchestrator's session: they are the workers the rule exists for.
public enum OrchestratorMarker {
  public static let environmentVariable = "SWIFT_HARNESS_ORCHESTRATOR"

  public static func isOrchestrator(
    environmentValue: String?, lockContents: String?, sessionID: String, agentID: String?
  ) -> Bool {
    guard agentID == nil else { return false }
    if environmentValue?.trimmingCharacters(in: .whitespacesAndNewlines) == "1" { return true }
    guard !sessionID.isEmpty, let lockContents else { return false }
    return lockContents.trimmingCharacters(in: .whitespacesAndNewlines) == sessionID
  }
}

/// Edit/Write guard over shared plan state and committed design artifacts (spec §4, §6.3). Only the
/// orchestrating main session writes them; workers report instead (spec §5.9).
///
/// Paths are classified after the caller has resolved them to absolute, symlink-free form, and
/// component names compare case-insensitively: the default APFS volume is case-insensitive, and a
/// component that does not exist yet keeps whatever case the caller spelled it in.
public enum PlanStateGuard {
  public enum Target: Sendable, Equatable {
    /// A plan's claim. Only `swiftgate plan claim|release` write it, never a tool edit.
    case orchestratorLock
    /// Under a plans root but naming no valid plan; nobody may write it.
    case malformedPlanPath
    /// Any file inside one plan's directory: writable by that plan's lock holder.
    case planFile(PlanStateLayout.Plan)
    /// `index.json` or any other file directly under a plans root: writable by any lock holder.
    case sharedPlanFile(PlanStateLayout)
    /// `docs/**/designs/*.md`, or anything under its `<doc>.evidence/` directory: writable only
    /// by the holder of the plan whose `plan.json` names `document`.
    case designArtifact(document: String)
  }

  /// One plan under the repository's common dir, as the caller read it.
  public struct PlanRecord: Sendable, Equatable {
    public enum Design: Sendable, Equatable {
      /// `plan.json`'s `design`, resolved to the same canonical form as the written path.
      case named(String)
      /// `plan.json` is missing or doesn't decode; the plan owns no design.
      case unreadable
    }

    public let name: String
    /// The lock's contents, `nil` when the plan is unclaimed.
    public let lock: String?
    public let design: Design

    public init(name: String, lock: String?, design: Design) {
      self.name = name
      self.lock = lock
      self.design = design
    }
  }

  /// Which locks decide a write to a plan-state target; the caller reads them, this type never
  /// does. A design artifact is decided by ``PlanRecord``s instead.
  public enum LockScope: Sendable, Equatable {
    case none
    case plan(PlanStateLayout.Plan)
    case everyPlan(PlanStateLayout)
  }

  /// `path` must be absolute with symlinks and `..` already resolved.
  public static func target(ofResolvedPath path: String) -> Target? {
    let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    let lowered = components.map { $0.lowercased() }
    if let target = planStateTarget(components, lowered) { return target }
    if let document = designDocument(components, lowered) {
      return .designArtifact(document: document)
    }
    return nil
  }

  public static func lockScope(of target: Target) -> LockScope {
    switch target {
    case .orchestratorLock, .malformedPlanPath, .designArtifact: .none
    case .planFile(let plan): .plan(plan)
    case .sharedPlanFile(let layout): .everyPlan(layout)
    }
  }

  /// `locks` holds the contents of each lock file in ``lockScope(of:)`` that exists; `plans`
  /// describes every plan for a ``Target/designArtifact(document:)``.
  public static func evaluate(
    _ target: Target, locks: [String], plans: [PlanRecord] = [], environmentValue: String?,
    sessionID: String, agentID: String?
  ) -> GuardViolation? {
    switch target {
    case .orchestratorLock:
      return violation(
        "orchestrator.lock is a plan's claim. Only `swiftgate plan claim <plan> --session <id>` "
          + "and `swiftgate plan release` write it; a hand edit would forge or steal the claim.")
    case .malformedPlanPath:
      return violation("this path names no valid plan under the shared plan state.")
    case .designArtifact(let document):
      let override = OrchestratorMarker.isOrchestrator(
        environmentValue: environmentValue, lockContents: nil, sessionID: sessionID,
        agentID: agentID)
      if override { return nil }
      if agentID != nil { return violation(workerReason("design docs and their `.evidence/`")) }
      let owners = plans.filter { $0.design == .named(document) }
      if owners.contains(where: { holds($0.lock, sessionID: sessionID, agentID: agentID) }) {
        return nil
      }
      if let owner = owners.first {
        return violation(
          "\(document) belongs to plan `\(owner.name)`, whose lock this session doesn't hold. "
            + "Only that plan's orchestrating session edits its design and `.evidence/`.")
      }
      let held = plans.filter { holds($0.lock, sessionID: sessionID, agentID: agentID) }
      if held.contains(where: { $0.design == .unreadable }) {
        return violation(
          "the plan.json of a plan this session holds is missing or unreadable, so it can't "
            + "own \(document). Fix plan.json before editing the design.")
      }
      return violation(
        "no plan's plan.json names \(document) as its design. Claim the plan first: "
          + "`swiftgate plan claim <slug> --session <id>`, with a plan.json whose `design` is "
          + "this doc. SWIFT_HARNESS_ORCHESTRATOR=1 overrides.")
    case .planFile, .sharedPlanFile:
      let allowed =
        OrchestratorMarker.isOrchestrator(
          environmentValue: environmentValue, lockContents: nil, sessionID: sessionID,
          agentID: agentID)
        || locks.contains { holds($0, sessionID: sessionID, agentID: agentID) }
      guard !allowed else { return nil }
      return violation(
        workerReason(
          "plan state (`plan.json`, `ledger.json`, `index.json` in the git common dir)"))
    }
  }

  private static func holds(_ lock: String?, sessionID: String, agentID: String?) -> Bool {
    OrchestratorMarker.isOrchestrator(
      environmentValue: nil, lockContents: lock, sessionID: sessionID, agentID: agentID)
  }

  private static func workerReason(_ what: String) -> String {
    what + " is written only by the main session holding the owning plan's lock. A worker "
      + "reports `design-conflict` or `needs-replan` instead. A main session claims a plan with "
      + "`swiftgate plan claim <slug> --session <id>`; SWIFT_HARNESS_ORCHESTRATOR=1 overrides. "
      + "A subagent never qualifies."
  }

  private static func violation(_ reason: String) -> GuardViolation {
    GuardViolation(ruleID: EditGuard.planStateRuleID, reason: reason)
  }

  /// The outermost `swift-harness/plans` pair decides, so a look-alike root nested inside a plan
  /// directory can't redirect the check to a lock the writer planted.
  private static func planStateTarget(_ components: [String], _ lowered: [String]) -> Target? {
    guard
      let index = lowered.indices.dropLast().first(where: {
        lowered[$0] == "swift-harness" && lowered[$0 + 1] == "plans"
      })
    else { return nil }
    let inside = components[(index + 2)...]
    guard !inside.isEmpty else { return nil }
    if inside.last?.lowercased() == "orchestrator.lock" { return .orchestratorLock }
    let common = "/" + components[..<index].joined(separator: "/")
    guard let layout = try? PlanStateLayout(commonDirectory: common) else {
      return .malformedPlanPath
    }
    guard inside.count >= 2 else { return .sharedPlanFile(layout) }
    guard let plan = try? layout.plan(inside[inside.startIndex]) else {
      return .malformedPlanPath
    }
    return .planFile(plan)
  }

  /// The design doc a path belongs to: itself, or `<dir>/<doc>.md` for anything under
  /// `<dir>/<doc>.evidence/`. The outermost evidence directory decides.
  private static func designDocument(_ components: [String], _ lowered: [String]) -> String? {
    if let index = lowered.indices.dropLast().first(where: { lowered[$0].hasSuffix(".evidence") }) {
      let stem = components[index].dropLast(".evidence".count)
      return "/" + (components[..<index] + [stem + ".md"]).joined(separator: "/")
    }
    guard lowered.count >= 3, let file = lowered.last, file.hasSuffix(".md"),
      lowered[lowered.count - 2] == "designs", lowered.dropLast(2).contains("docs")
    else { return nil }
    return "/" + components.joined(separator: "/")
  }
}

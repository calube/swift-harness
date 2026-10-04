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
      return ShellSyntax.gitInvocation(simple.arguments).subcommand == "commit"
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
}

/// PreToolUse guard on the commands that write plan locks and the plan index: a tool call acts
/// only as its own main session. Taking over another session's lock (`plan release --force`) is
/// the user's call alone, so no tool call may run it. Judged by the command's shape; the commands
/// themselves check the lock.
public enum PlanCommandGuard {
  private static let sessionCommands: Set<[String]> = [
    ["plan", "claim"], ["plan", "release"], ["plan", "set"], ["index", "set"],
    ["ledger", "set"], ["build", "start"], ["build", "finish"], ["worktree", "create"],
    ["build", "merge"],
  ]
  /// The build executor's verbs: a subagent reaching one is a build worker, which hands its result
  /// back rather than reporting a design conflict.
  private static let buildCommands: Set<[String]> = [
    ["ledger", "set"], ["build", "start"], ["build", "finish"], ["worktree", "create"],
    ["build", "merge"],
  ]

  public static func evaluate(_ command: String, sessionID: String, agentID: String?)
    -> GuardViolation?
  {
    for simple in ShellSyntax.simpleCommands(in: command) {
      guard let arguments = swiftgateArguments(simple),
        let verb = sessionCommand(in: arguments)
      else { continue }
      let spelled = "`swiftgate \(verb.joined(separator: " "))`"
      if verb == ["plan", "release"], arguments.contains("--force") {
        return violation(
          "`swiftgate plan release --force` takes over a lock another session holds. Only the user "
            + "runs it, in their own terminal, once they know that session has ended. Ask the user."
        )
      }
      if agentID != nil, buildCommands.contains(verb) {
        return violation(
          "a subagent never runs \(spelled): task statuses, build runs and worktrees belong to the "
            + "orchestrator, the main session that runs the build. A build worker returns its task "
            + "result to the orchestrator instead.")
      }
      if agentID != nil {
        return violation(
          "a subagent never runs \(spelled): claiming, releasing and indexing a plan belong to the "
            + "main session that orchestrates it. Report `design-conflict` or `needs-replan` to it "
            + "instead.")
      }
      if let session = sessions(in: arguments).first(where: { $0 != sessionID || $0.isEmpty }) {
        return violation(
          "\(spelled) names session `\(session)`, and this session is `\(sessionID)`. A tool call "
            + "acts only as its own session: pass the literal id from the SessionStart context. If "
            + "another session holds the plan, ask the user.")
      }
    }
    return nil
  }

  /// The arguments `swiftgate` receives, whether it is run by any path or through `swift run`.
  private static func swiftgateArguments(_ command: SimpleCommand) -> [String]? {
    if command.name == "swiftgate" { return command.arguments }
    guard command.name == "swift", command.arguments.first == "run",
      let product = command.arguments.firstIndex(of: "swiftgate")
    else { return nil }
    return Array(command.arguments[(product + 1)...])
  }

  private static func sessionCommand(in arguments: [String]) -> [String]? {
    zip(arguments, arguments.dropFirst()).map { [$0, $1] }.first(where: sessionCommands.contains)
  }

  /// Every `--session` value, in both spellings; a repeated option is judged in full because the
  /// parser keeps only one of them.
  private static func sessions(in arguments: [String]) -> [String] {
    var values: [String] = []
    for (index, argument) in arguments.enumerated() {
      if argument == "--session" {
        values.append(index + 1 < arguments.count ? arguments[index + 1] : "")
      } else if argument.hasPrefix("--session=") {
        values.append(String(argument.dropFirst("--session=".count)))
      }
    }
    return values
  }

  private static func violation(_ reason: String) -> GuardViolation {
    GuardViolation(ruleID: EditGuard.planStateRuleID, reason: reason)
  }
}

/// PreToolUse guards on Edit/Write paths (spec §8): recorded or generated artifacts. Plan state
/// and design artifacts are ``PlanStateGuard``'s.
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
    /// A plan's claim, or a lock file serialising claims, index or ledger writes, or event
    /// appends (`claim.lock.*`, `index.lock.*`, `ledger.lock.*`, `events.lock.*`). Only
    /// `swiftgate` writes them, never a tool edit.
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
    /// A sprint's spec page, `<plans>/sprints/<name>.md`: no plan owns it, so any main session
    /// writes it and a subagent never does.
    case sprintPage
  }

  /// One plan under the repository's common dir, as the caller read it.
  public struct PlanRecord: Sendable, Equatable {
    public enum Design: Sendable, Equatable {
      /// `plan.json`'s `design`, resolved to the same canonical form as the written path.
      case named(String)
      /// `plan.json` is missing or doesn't decode; the plan owns no design.
      case unreadable
      /// `plan.json` names a spec page as the plan's source; the plan owns no design.
      case specPage
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

  /// `path` must be absolute with symlinks and `..` already resolved. `isDirectory` says the path
  /// is an existing directory, which makes one directly under a plans root that plan's directory.
  public static func target(ofResolvedPath path: String, isDirectory: Bool = false) -> Target? {
    let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    let lowered = components.map { $0.lowercased() }
    if let target = planStateTarget(components, lowered, isDirectory: isDirectory) {
      return target
    }
    if let document = designDocument(components, lowered) {
      return .designArtifact(document: document)
    }
    return nil
  }

  public static func lockScope(of target: Target) -> LockScope {
    switch target {
    case .orchestratorLock, .malformedPlanPath, .designArtifact, .sprintPage: .none
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
        "orchestrator.lock is a plan's claim, and the claim.lock and index.lock files serialise "
          + "claims and index writes. Only `swiftgate plan claim <plan> --session <id>`, "
          + "`swiftgate plan release` and `swiftgate index set` write them; a hand edit would forge "
          + "or steal a claim.")
    case .malformedPlanPath:
      return violation("this path names no valid plan under the shared plan state.")
    case .sprintPage:
      guard agentID != nil else { return nil }
      return violation(
        "a sprint's spec page is written only by the main session running the sprint; a subagent "
          + "never qualifies. Report what the page should say instead.")
    case .designArtifact(let document):
      let override = OrchestratorMarker.isOrchestrator(
        environmentValue: environmentValue, lockContents: nil, sessionID: sessionID,
        agentID: agentID)
      if override { return nil }
      if agentID != nil { return violation(workerReason("design docs and their `.evidence/`")) }
      let owners = plans.filter { $0.design == .named(document) }
      if owners.count > 1 {
        return violation(
          "\(document) is named as the design of plans "
            + owners.map { "`\($0.name)`" }.joined(separator: " and ")
            + ", and exactly one plan may own a design. Until only one plan.json names it, nobody "
            + "edits it or its `.evidence/`; ask the user which plan owns it.")
      }
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

  /// The `design` a write leaves in a plan's `plan.json`.
  public enum WrittenDesign: Sendable, Equatable {
    /// Resolved to the same canonical form as ``PlanRecord/Design/named(_:)``.
    case named(String)
    /// The written content doesn't decode as a plan file.
    case unreadable
    /// The written content is a spec-page plan, which names no design.
    case specPage
    /// The content can't be known before the write, as with a shell command.
    case unknown
  }

  /// Judges a write to `plan`'s `plan.json` that ``evaluate(_:locks:plans:environmentValue:sessionID:agentID:)``
  /// already allowed: `design` ties a plan to the one doc it may edit, so a write may not move it.
  /// A plan whose current `plan.json` is missing or unreadable may name a design no other plan
  /// names. `plans` describes every plan, `plan` included.
  public static func evaluatePlanFile(
    of plan: String, writing written: WrittenDesign, plans: [PlanRecord],
    environmentValue: String?, agentID: String?
  ) -> GuardViolation? {
    let override = OrchestratorMarker.isOrchestrator(
      environmentValue: environmentValue, lockContents: nil, sessionID: "", agentID: agentID)
    if override { return nil }
    let current = plans.first(where: { $0.name == plan })?.design ?? .unreadable
    switch written {
    case .unknown:
      return violation(
        "plan.json names the one design its plan may edit, and a shell write's content can't be "
          + "checked before it runs. Edit plan.json with the Edit or Write tool.")
    case .unreadable:
      return violation(
        "the written plan.json doesn't decode as a plan file, so its plan would lose its design. "
          + "Keep plan.json valid.")
    case .specPage:
      guard case .named(let kept) = current else { return nil }
      return violation(
        "plan.json names \(kept) as the design of plan `\(plan)`; a write may not turn it into a "
          + "spec-page plan and drop its design. A spec-page plan is a different plan: claim it with "
          + "`swiftgate plan claim <slug> --session <id> --spec-page`.")
    case .named(let design):
      if current == .specPage {
        return violation(
          "plan `\(plan)` is a spec-page plan; a write may not give it the design \(design). A "
            + "design is a different plan: claim it with "
            + "`swiftgate plan claim <slug> --session <id> --design <doc>`.")
      }
      if case .named(let kept) = current {
        guard kept != design else { return nil }
        return violation(
          "plan.json names \(kept) as the design of plan `\(plan)`; a write may not repoint it to "
            + "\(design). A different design is a different plan: claim it with "
            + "`swiftgate plan claim <slug> --session <id> --design <doc>`.")
      }
      if let owner = plans.first(where: { $0.name != plan && $0.design == .named(design) }) {
        return violation(
          "\(design) belongs to plan `\(owner.name)`; exactly one plan may own a design.")
      }
      return nil
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
  private static func planStateTarget(
    _ components: [String], _ lowered: [String], isDirectory: Bool
  ) -> Target? {
    guard
      let index = lowered.indices.dropLast().first(where: {
        lowered[$0] == "swift-harness" && lowered[$0 + 1] == "plans"
      })
    else { return nil }
    let inside = components[(index + 2)...]
    guard !inside.isEmpty else { return nil }
    if let last = inside.last?.lowercased(),
      last == "orchestrator.lock" || last.hasPrefix("claim.lock") || last.hasPrefix("index.lock")
        || last.hasPrefix("ledger.lock") || last.hasPrefix("events.lock")
    {
      return .orchestratorLock
    }
    let common = "/" + components[..<index].joined(separator: "/")
    guard let layout = try? PlanStateLayout(commonDirectory: common) else {
      return .malformedPlanPath
    }
    if inside.first?.lowercased() == PlanStateLayout.sprintsDirectoryName {
      guard inside.count == 2, !isDirectory, let page = inside.last?.lowercased(),
        page.count > ".md".count, page.hasSuffix(".md")
      else { return .malformedPlanPath }
      return .sprintPage
    }
    guard inside.count >= 2 || isDirectory else { return .sharedPlanFile(layout) }
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

/// A background subagent can't answer a permission prompt: a tool call that raises one never runs,
/// and the agent waits until someone stops it. So the PreToolUse hook decides every call a
/// subagent makes, and never leaves one to the prompt. A write outside this repository's
/// checkouts is denied with a reason the agent can act on; a build worker's or fixer's write to
/// the main checkout is denied too, since each owns only its task worktree. Every other call is
/// allowed.
public enum SubagentScopeGuard {
  public static let outsideCheckoutsRuleID = "guard.subagent-outside-checkouts"
  public static let buildAgentMainCheckoutRuleID = "guard.build-agent-main-checkout"
  public static let protectedPathRuleID = "guard.subagent-protected-path"
  /// Directories Claude Code prompts for whatever a hook decides, so a subagent's write there
  /// would still hang.
  public static let protectedDirectories: Set<String> = [".git", ".claude", ".vscode", ".idea"]
  /// The agents that build in a task worktree and must never write the main checkout.
  public static let buildAgentTypes: Set<String> = [
    "swift-harness:build-worker", "swift-harness:build-fixer",
  ]

  /// The repository's checkouts, as canonical absolute paths.
  public struct Checkouts: Sendable, Equatable {
    public let main: String
    public let linkedWorktrees: Set<String>

    public init(main: String, linkedWorktrees: Set<String>) {
      self.main = main
      self.linkedWorktrees = linkedWorktrees
    }
  }

  /// The first write that breaks the scope, or `nil` when every write is inside it.
  /// - Parameter writes: canonical absolute paths the call writes.
  public static func evaluate(writes: [String], agentType: String?, checkouts: Checkouts)
    -> GuardViolation?
  {
    let isBuildAgent = agentType.map(buildAgentTypes.contains) ?? false
    for path in writes {
      if path.split(separator: "/").contains(where: { protectedDirectories.contains(String($0)) }) {
        return GuardViolation(
          ruleID: protectedPathRuleID,
          reason:
            "`\(path)` is in a directory Claude Code always asks about, and a background agent "
            + "can't answer. Change git state with git commands, never by writing its files.")
      }
      // `/dev/null` and the other device files take output; they write no file.
      if path.hasPrefix("/dev/") { continue }
      if checkouts.linkedWorktrees.contains(where: { contains($0, path) }) { continue }
      if contains(checkouts.main, path) {
        guard isBuildAgent else { continue }
        return GuardViolation(
          ruleID: buildAgentMainCheckoutRuleID,
          reason:
            "`\(path)` is in the main checkout. A build agent writes only inside its task "
            + "worktree; the orchestrator merges to main.")
      }
      return GuardViolation(
        ruleID: outsideCheckoutsRuleID,
        reason:
          "`\(path)` is outside this repository's checkouts. A background agent can't answer a "
          + "permission prompt, so writes stay inside your worktree. For a scratch file, use "
          + "`.harness/tmp/` there; to prove a test guards the code, break the file with Edit and "
          + "put it back with `git restore <file>`.")
    }
    return nil
  }

  private static func contains(_ root: String, _ path: String) -> Bool {
    path == root || path.hasPrefix(root + "/")
  }
}

/// `discover/dirty.json`: the repository-relative paths `git status` showed as modified or
/// untracked when discovery ran. They are the user's work in progress, never a worker's.
public struct DirtyFileList: Sendable, Equatable, Codable {
  public let paths: [String]

  public init(paths: [String]) {
    self.paths = paths
  }
}

/// Denies a Bash command that would stage a file in ``DirtyFileList``: `git add` or `git stage`
/// naming it or a directory above it, an all-files form (`-A`, `-u`, `.` at the root), and
/// `git commit -a` or `git commit <path>`.
public enum DirtyFileGuard {
  public static let ruleID = "guard.dirty-file"

  /// - Parameters:
  ///   - cwd: the absolute directory the command runs in.
  ///   - repositoryRoot: the absolute worktree root the dirty paths are relative to.
  public static func evaluate(
    _ command: String, cwd: String, repositoryRoot: String, dirty: DirtyFileList
  ) -> GuardViolation? {
    guard !dirty.paths.isEmpty else { return nil }
    let root = lexical(repositoryRoot)
    for simple in ShellSyntax.simpleCommands(in: command) where simple.name == "git" {
      let git = ShellSyntax.gitInvocation(simple.arguments)
      let directory = git.directory.map { absolute($0, in: cwd) } ?? cwd
      let staged: Staging
      switch git.subcommand {
      case "add"?, "stage"?: staged = addStaging(Array(git.arguments))
      case "commit"?: staged = commitStaging(Array(git.arguments))
      default: continue
      }
      let hit: [String]
      switch staged {
      case .nothing: continue
      case .everything: hit = dirty.paths
      case .pathspecs(let specs):
        let covered = specs.compactMap { relative(absolute($0, in: directory), to: root) }
        hit = dirty.paths.filter { path in
          covered.contains { $0.isEmpty || path == $0 || path.hasPrefix($0 + "/") }
        }
      }
      guard !hit.isEmpty else { continue }
      return GuardViolation(
        ruleID: ruleID,
        reason:
          "this would stage \(hit.sorted().joined(separator: ", ")), which held uncommitted work "
          + "before this run started; that work is the user's, so stage your own files by name")
    }
    return nil
  }

  private enum Staging {
    case nothing
    case everything
    case pathspecs([String])
  }

  /// `git add` options that consume the next word.
  private static let addOptionsWithValues: Set<String> = ["--chmod", "--pathspec-from-file"]
  /// `git commit` short options that consume the rest of their cluster or the next word.
  private static let commitShortValues: Set<Character> = ["m", "F", "C", "c", "t"]
  private static let commitLongValues: Set<String> = [
    "--message", "--file", "--reuse-message", "--reedit-message", "--template", "--author",
    "--date", "--cleanup", "--fixup", "--squash", "--trailer", "--pathspec-from-file",
  ]

  private static func addStaging(_ arguments: [String]) -> Staging {
    var specs: [String] = []
    var all = false
    var rest = arguments[...]
    while let word = rest.popFirst() {
      if word == "--" {
        specs += rest
        break
      }
      switch word {
      case "-n", "--dry-run": return .nothing
      case "-A", "--all", "-u", "--update", "--no-ignore-removal": all = true
      case let option where addOptionsWithValues.contains(option): _ = rest.popFirst()
      case let option where option.hasPrefix("-"): continue
      default: specs.append(word)
      }
    }
    if specs.isEmpty { return all ? .everything : .nothing }
    return .pathspecs(specs)
  }

  private static func commitStaging(_ arguments: [String]) -> Staging {
    var specs: [String] = []
    var all = false
    var rest = arguments[...]
    while let word = rest.popFirst() {
      if word == "--" {
        specs += rest
        break
      }
      if word.hasPrefix("--") {
        let name = String(word.prefix { $0 != "=" })
        if name == "--all" { all = true }
        if commitLongValues.contains(name), !word.contains("=") { _ = rest.popFirst() }
      } else if word.hasPrefix("-"), word.count > 1 {
        for (offset, flag) in word.dropFirst().enumerated() {
          if flag == "a" { all = true }
          if commitShortValues.contains(flag) {
            if offset == word.count - 2 { _ = rest.popFirst() }
            break
          }
        }
      } else {
        specs.append(word)
      }
    }
    if all { return .everything }
    return specs.isEmpty ? .nothing : .pathspecs(specs)
  }

  private static func absolute(_ path: String, in directory: String) -> String {
    lexical(path.hasPrefix("/") ? path : directory + "/" + path)
  }

  /// `path` relative to `root`, `""` for the root itself, `nil` outside it.
  private static func relative(_ path: String, to root: String) -> String? {
    if path == root { return "" }
    let prefix = root == "/" ? "/" : root + "/"
    return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
  }

  /// `.` and `..` removed without touching the filesystem.
  private static func lexical(_ path: String) -> String {
    var parts: [Substring] = []
    for part in path.split(separator: "/") {
      switch part {
      case ".": continue
      case "..": _ = parts.popLast()
      default: parts.append(part)
      }
    }
    return "/" + parts.joined(separator: "/")
  }
}

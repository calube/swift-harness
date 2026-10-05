import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import Synchronization

/// PreToolUse (spec §8): Bash, Monitor and Edit/Write guards (< 50ms), and the advisory comment
/// pass on `git commit` (≤ 20s). A path a Bash command writes is judged exactly as a file tool's
/// path.
enum PreToolUseHook {
  static let fileTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

  /// The JSON to print, or `nil` to leave the call to the normal permission flow. A subagent's
  /// call is never left to that flow: a background agent can't answer a prompt, so it gets an
  /// explicit allow or deny.
  /// - Parameter brownfield: the clone's state when it runs the brownfield profile, which adds
  ///   the dirty-file guard and drops this harness's comment advice on a commit.
  static func run(
    _ payload: HookPayload, root: URL, dependencies: HookDependencies,
    brownfield: BrownfieldStateLayout? = nil
  ) async -> String? {
    let home = dependencies.environment["HOME"]
    let reads = PlanStateReads(root: root, sessionID: payload.sessionID, dependencies: dependencies)
    var writes: [String] = []
    var context: String?
    switch payload.toolName {
    case "Bash"?:
      guard let command = payload.command else { break }
      if let violation = ReviewerBashGuard.evaluate(command, agentType: payload.agentType) {
        return deny(violation, tool: payload.toolName)
      }
      if let violation = BashGuard.evaluate(command, inSubagent: payload.agentID != nil) {
        return deny(violation, tool: payload.toolName)
      }
      if let violation = await gateOutput(
        command, payload: payload, root: root, reads: reads, home: home)
      {
        return deny(violation, note: reads.note, tool: payload.toolName)
      }
      if let violation = fixerGateCap(command, payload: payload) {
        return deny(violation, tool: payload.toolName)
      }
      if let brownfield {
        switch DirtyFileRead.read(brownfield.discoverDirty) {
        case .absent: break
        case .listed(let dirty):
          if let violation = DirtyFileGuard.evaluate(
            command, cwd: payload.cwd, repositoryRoot: root.path, dirty: dirty)
          {
            return deny(violation, tool: payload.toolName)
          }
        case .unreadable(let path, let reason):
          context = joined(
            context,
            "swiftgate: \(path) can't be read (\(reason)), so staging isn't checked against the "
              + "files that held uncommitted work before this run; stage only files you wrote")
        }
      }
      if let violation = PlanCommandGuard.evaluate(
        command, sessionID: payload.sessionID, agentID: payload.agentID)
      {
        return deny(violation, tool: payload.toolName)
      }
      for path in writtenPaths(command, payload: payload, home: home) {
        if let violation = await writeViolation(
          path, payload: payload, root: root, dependencies: dependencies, reads: reads)
        {
          let reason = "this command writes `\(path)`. " + violation.reason
          return deny(
            GuardViolation(ruleID: violation.ruleID, reason: reason), note: reads.note,
            tool: payload.toolName)
        }
        writes.append(path)
      }
      if brownfield == nil, BashGuard.isGitCommit(command) {
        context = joined(context, await commitContext(root: root, dependencies: dependencies))
      }
    case "Monitor"?:
      // A Monitor command is a shell script too: what the Bash guards deny, such as a wait on
      // `pgrep`, it may not run either. Anything else goes to the normal permission flow.
      guard let command = payload.command else { return nil }
      if let violation = BashGuard.evaluate(command, inSubagent: payload.agentID != nil) {
        return deny(violation)
      }
      return nil
    case "Agent"?:
      // Only the launch guard reads an Agent call; the rest goes to the normal permission flow.
      if let violation = BuildAgentLaunchGuard.evaluate(
        subagentType: payload.subagentType, runInBackground: payload.runInBackground)
      {
        return deny(violation, tool: payload.toolName)
      }
      return nil
    case let tool? where fileTools.contains(tool):
      guard let path = payload.filePath else { break }
      if let violation = await writeViolation(
        path, payload: payload, root: root, dependencies: dependencies, reads: reads)
      {
        return deny(violation, note: reads.note, tool: payload.toolName)
      }
      writes.append(path)
    default:
      break
    }
    guard payload.agentID != nil else {
      return joined(context, reads.note).map { HookOutput.context(.preToolUse, $0) }
    }
    let resolved = writes.flatMap { ToolPath.resolvedAbsolutes($0, cwd: payload.cwd, home: home) }
    let checkouts = await RepositoryCheckouts.of(root: root, reads: reads, around: resolved)
    if let violation = SubagentScopeGuard.evaluate(
      writes: resolved, agentType: payload.agentType, checkouts: checkouts)
    {
      return deny(violation, note: reads.note, tool: payload.toolName)
    }
    return HookOutput.allow(
      "swiftgate: a background agent can't answer a permission prompt, so the hook decides",
      context: joined(context, reads.note))
  }

  private static func joined(_ context: String?, _ note: String?) -> String? {
    let parts = [context, note].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
  }

  /// The paths a Bash command writes. A copy, move or link into a directory writes each source's
  /// name inside it, which only the filesystem can tell from a copy onto a new file's name.
  private static func writtenPaths(_ command: String, payload: HookPayload, home: String?)
    -> [String]
  {
    ShellSyntax.writeTargets(in: command, directoryExists: isDirectory).flatMap {
      target -> [String] in
      guard !target.entries.isEmpty,
        target.isDirectory
          || ToolPath.resolvedAbsolutes(target.path, cwd: payload.cwd, home: home)
            .contains(where: isDirectory)
      else { return [target.path] }
      return [target.path] + target.entries.map { target.path + "/" + $0 }
    }
  }

  /// A `swiftgate` output file the command names outside the repository's checkouts and its git
  /// common dir, judged at its canonical path so `/tmp` and `/private/tmp` read alike.
  private static func gateOutput(
    _ command: String, payload: HookPayload, root: URL, reads: PlanStateReads, home: String?
  ) async -> GuardViolation? {
    let spelled = GateOutputGuard.outputTargets(in: command)
    guard !spelled.isEmpty else { return nil }
    let targets = spelled.flatMap { target in
      ToolPath.resolvedAbsolutes(target, cwd: payload.cwd, home: home).prefix(1)
    }.map(ToolPath.canonical)
    let checkouts = await RepositoryCheckouts.of(root: root, reads: reads, around: targets)
    let common = (try? await reads.commonDirectory()).map(ToolPath.canonical)
    let plans =
      common.flatMap { try? PlanStateLayout(commonDirectory: $0).root }
      ?? "<git common dir>/swift-harness/plans"
    return GateOutputGuard.evaluate(
      targets: targets,
      allowedRoots: [checkouts.main] + checkouts.linkedWorktrees.sorted()
        + (common.map { [$0] } ?? []),
      outFolder: plans + "/<plan>/out/")
  }

  /// The fixer's full-gate cap, counted in the run history of each worktree the command gates.
  private static func fixerGateCap(_ command: String, payload: HookPayload) -> GuardViolation? {
    guard payload.agentType == FixerGateCapGuard.agentType else { return nil }
    for call in FixerGateCapGuard.gateCalls(
      in: command, cwd: payload.cwd, directoryExists: isDirectory)
    {
      let records =
        worktreeRoot(holding: call.directory).flatMap {
          try? RunStore(worktreeRoot: $0).readHistory().records
        } ?? []
      if let violation = FixerGateCapGuard.evaluate(
        call, priorRuns: FixerGateCapGuard.cappedRuns(in: records), agentType: payload.agentType)
      {
        return violation
      }
    }
    return nil
  }

  /// The nearest directory at or above `directory` holding a `.swiftgate.toml` or a `.git`: where
  /// `check` keeps its runs.
  private static func worktreeRoot(holding directory: String) -> URL? {
    var current = URL(filePath: directory, directoryHint: .isDirectory).standardizedFileURL
    while true {
      for marker in [Config.fileName, ".git"]
      where FileManager.default.fileExists(atPath: current.appending(path: marker).path) {
        return current
      }
      let parent = current.deletingLastPathComponent()
      guard parent.path != current.path else { return nil }
      current = parent
    }
  }

  private static func isDirectory(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }

  /// The one judgment of a write, whether a file tool names the path or a Bash command writes
  /// it. Every guard sees every spelling of the path the write could land on, so a relative,
  /// `..`-bearing or symlinked form is judged like the canonical one.
  static func writeViolation(
    _ path: String, payload: HookPayload, root: URL, dependencies: HookDependencies,
    reads: PlanStateReads
  ) async -> GuardViolation? {
    let environmentValue = dependencies.environment[OrchestratorMarker.environmentVariable]
    let forms = ToolPath.resolvedForms(
      path, cwd: payload.cwd, home: dependencies.environment["HOME"])
    for form in forms {
      if let violation = EditGuard.evaluate(path: form) { return violation }
    }
    for form in ToolPath.resolvedAbsolutes(
      path, cwd: payload.cwd, home: dependencies.environment["HOME"])
    {
      guard
        var target = PlanStateGuard.target(
          ofResolvedPath: form, isDirectory: isDirectory(form))
      else { continue }
      var plans: [PlanStateGuard.PlanRecord] = []
      var planFile: PlanStateLayout.Plan?
      if case .designArtifact(let document) = target {
        target = .designArtifact(document: ToolPath.canonical(document))
        plans = await PlanLocks.records(reads)
      } else if case .planFile(let plan) = target, form.lowercased() == plan.planFile.lowercased() {
        planFile = plan
      }
      let locks = PlanLocks.read(PlanStateGuard.lockScope(of: target))
      if let violation = PlanStateGuard.evaluate(
        target, locks: locks, plans: plans, environmentValue: environmentValue,
        sessionID: payload.sessionID, agentID: payload.agentID)
      {
        return violation
      }
      if let planFile {
        let name = URL(filePath: planFile.directory).lastPathComponent
        if let violation = PlanStateGuard.evaluatePlanFile(
          of: name, writing: writtenDesign(form, payload: payload, root: root),
          plans: await PlanLocks.records(reads),
          environmentValue: environmentValue, agentID: payload.agentID)
        {
          return violation
        }
      }
    }
    return nil
  }

  /// The design a file tool leaves in `plan.json`; a shell write's is unknown until it runs.
  private static func writtenDesign(_ planFile: String, payload: HookPayload, root: URL)
    -> PlanStateGuard.WrittenDesign
  {
    guard let tool = payload.toolName, fileTools.contains(tool), let write = payload.fileWrite
    else { return .unknown }
    let current = try? String(contentsOfFile: planFile, encoding: .utf8)
    guard let text = write.result(over: current),
      let file = try? PlanFileJSON.decode(Data(text.utf8))
    else { return .unreadable }
    guard let source = file.designSource else { return .specPage }
    guard !source.design.isEmpty else { return .unreadable }
    return .named(PlanLocks.resolve(design: source.design, root: root))
  }

  /// A cache fault's note rides along after the reason; it never changes the decision.
  static func deny(_ violation: GuardViolation, note: String? = nil, tool: String?) -> String {
    let reason = "swiftgate \(violation.ruleID): \(violation.denialReason(forTool: tool))"
    return HookOutput.deny(note.map { reason + "\n\n" + $0 } ?? reason)
  }

  /// Runs on what is staged when the hook fires, so `git add … && git commit` in one command is
  /// checked by the git pre-commit hook rather than here. Advisory: it never denies the commit.
  /// The comment check and commit judge's advice on a `git commit`, as plain text.
  private static func commitContext(root: URL, dependencies: HookDependencies) async -> String? {
    var sections: [String] = []
    let outcome = await CommentsCheck.run(
      root: root, git: dependencies.git, swiftPM: dependencies.swiftPM)
    if let report = try? StaticCheckReport.make(
      runID: "hook", durationMilliseconds: 0, outcome: outcome), !report.findings.isEmpty
    {
      sections.append(
        "`swiftgate comments --staged` on this commit (advisory here; the git pre-commit hook "
          + "enforces the blocking rules):\n" + HookText.findings(report))
    }
    if let judged = await dependencies.commitJudge.review(root: root) { sections.append(judged) }
    guard !sections.isEmpty else { return nil }
    return sections.joined(separator: "\n\n")
  }
}

/// The repository's checkouts that `paths` could land in: the main checkout holds the git common
/// dir, and a linked worktree is a sibling `<repo>-…` directory whose `.git` is a file. Only each
/// path's own candidate sibling is checked, never a directory listing, so the hook stays fast
/// however full the parent directory is.
enum RepositoryCheckouts {
  static func of(root: URL, reads: PlanStateReads, around paths: [String]) async
    -> SubagentScopeGuard.Checkouts
  {
    let common = (try? await reads.commonDirectory()).map { URL(filePath: $0) }
    let main = common?.deletingLastPathComponent() ?? root
    let mainPath = ToolPath.canonical(main.path)
    let parent = URL(filePath: mainPath).deletingLastPathComponent().path
    let prefix = URL(filePath: mainPath).lastPathComponent + "-"
    var linked: Set<String> = []
    for path in paths where path.hasPrefix(parent + "/") {
      guard let entry = path.dropFirst(parent.count + 1).split(separator: "/").first,
        entry.hasPrefix(prefix)
      else { continue }
      let candidate = parent + "/" + entry
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: candidate + "/.git", isDirectory: &isDirectory),
        !isDirectory.boolValue
      else { continue }
      linked.insert(candidate)
    }
    let current = ToolPath.canonical(root.path)
    if current != mainPath { linked.insert(current) }
    return SubagentScopeGuard.Checkouts(main: mainPath, linkedWorktrees: linked)
  }
}

enum HookText {
  static let maxFindings = 20

  /// One line per finding, most severe first, capped.
  static func findings(_ report: RunReport) -> String {
    let ordered = report.findings.enumerated()
      .sorted { ($0.element.severity.rank, $0.offset) < ($1.element.severity.rank, $1.offset) }
      .map(\.element)
    var lines = ordered.prefix(maxFindings).map { finding in
      let location = finding.line.map { "\(finding.file):\($0)" } ?? finding.file
      return "- [\(finding.severity.rawValue)] \(finding.ruleID) \(location): \(finding.message)"
    }
    if ordered.count > maxFindings { lines.append("- … \(ordered.count - maxFindings) more") }
    return lines.joined(separator: "\n")
  }
}

/// The absolute paths a file tool's `file_path` can land on.
enum ToolPath {
  /// Bounds symlink expansion, as the kernel's `MAXSYMLINKS` does, so a loop can't hang the hook.
  static let maxSymlinkHops = 32

  /// The path as given, its lexical resolution (`..` removed, then symlinks resolved), and its
  /// physical resolution (each component's symlink followed before a later `..` applies, as the
  /// kernel does, including a dangling link a write would create the target of). A relative path
  /// resolves against `cwd`; a leading `~/` also resolves against `home`.
  static func resolvedForms(_ path: String, cwd: String, home: String?) -> [String] {
    var forms: [String] = [path]
    for form in absolutes(path, cwd: cwd, home: home)
      + resolvedAbsolutes(path, cwd: cwd, home: home) where !forms.contains(form)
    {
      forms.append(form)
    }
    return forms
  }

  /// Only the canonical forms of ``resolvedForms(_:cwd:home:)``: every place the write can land,
  /// spelled so it compares equal to another canonical path naming the same file.
  static func resolvedAbsolutes(_ path: String, cwd: String, home: String?) -> [String] {
    var forms: [String] = []
    for absolute in absolutes(path, cwd: cwd, home: home) {
      for form in [CanonicalPath.of(URL(filePath: absolute)), canonical(absolute)]
      where !forms.contains(form) {
        forms.append(form)
      }
    }
    return forms
  }

  /// ``physical(_:)``, then `realpath` over what exists, which also settles letter case.
  static func canonical(_ absolute: String) -> String {
    CanonicalPath.of(URL(filePath: physical(absolute)))
  }

  private static func absolutes(_ path: String, cwd: String, home: String?) -> [String] {
    guard !path.hasPrefix("/") else { return [path] }
    var absolutes = [cwd + "/" + path]
    if let home, path.hasPrefix("~/") { absolutes.append(home + "/" + path.dropFirst(2)) }
    return absolutes
  }

  static func physical(_ absolute: String) -> String {
    var pending = components(absolute)
    var resolved: [String] = []
    var hops = 0
    while !pending.isEmpty {
      let next = pending.removeFirst()
      switch next {
      case ".":
        continue
      case "..":
        _ = resolved.popLast()
      default:
        let candidate = "/" + (resolved + [next]).joined(separator: "/")
        if hops < maxSymlinkHops,
          let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate)
        {
          hops += 1
          if destination.hasPrefix("/") { resolved = [] }
          pending = components(destination) + pending
        } else {
          resolved.append(next)
        }
      }
    }
    return "/" + resolved.joined(separator: "/")
  }

  private static func components(_ path: String) -> [String] {
    path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
  }
}

/// Reads plan locks for the guard. Read-only by contract: claiming is `swiftgate plan claim`'s job.
enum PlanLocks {
  static func read(_ scope: PlanStateGuard.LockScope) -> [String] {
    switch scope {
    case .none:
      return []
    case .plan(let plan):
      return contents(plan.orchestratorLock).map { [$0] } ?? []
    case .everyPlan(let layout):
      return every(layout)
    }
  }

  /// Every plan under the repository's common dir with the design its `plan.json` names. None
  /// when git can't place the common dir, so only the override can allow a design write.
  static func records(_ reads: PlanStateReads) async -> [PlanStateGuard.PlanRecord] {
    let root = reads.root
    guard let common = try? await reads.commonDirectory(),
      let layout = try? PlanStateLayout(commonDirectory: common)
    else { return [] }
    let names = (try? FileManager.default.contentsOfDirectory(atPath: layout.root)) ?? []
    return names.sorted().compactMap { name in
      guard let plan = try? layout.plan(name) else { return nil }
      let design: PlanStateGuard.PlanRecord.Design
      if let data = FileManager.default.contents(atPath: plan.planFile),
        let file = try? PlanFileJSON.decode(data)
      {
        if let source = file.designSource {
          design =
            source.design.isEmpty ? .unreadable : .named(resolve(design: source.design, root: root))
        } else {
          design = .specPage
        }
      } else {
        design = .unreadable
      }
      return PlanStateGuard.PlanRecord(
        name: name, lock: contents(plan.orchestratorLock), design: design)
    }
  }

  /// A `plan.json` `design`, canonical. A relative one is relative to the project root, the
  /// directory holding `.swiftgate.toml`, as `plan claim`, `evidence check` and plan-lint read it,
  /// so a project nested below the git root names its docs the same way to all of them.
  static func resolve(design: String, root: URL) -> String {
    ToolPath.canonical(design.hasPrefix("/") ? design : CanonicalPath.of(root) + "/" + design)
  }

  private static func every(_ layout: PlanStateLayout) -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: layout.root)) ?? []
    return names.sorted().compactMap { name in
      (try? layout.plan(name)).flatMap { contents($0.orchestratorLock) }
    }
  }

  private static func contents(_ path: String) -> String? {
    try? String(contentsOfFile: path, encoding: .utf8)
  }
}

/// One hook call's reads of plan state: the git common dir through the session's
/// ``PlanLockCache``, and the notes a cache fault leaves for the hook's output.
final class PlanStateReads: Sendable {
  let root: URL
  private let git: any Git
  private let cache: PlanLockCache?
  private let environment: [String: String]
  private let notes = Mutex<[String]>([])

  init(root: URL, sessionID: String, dependencies: HookDependencies) {
    self.root = root
    git = dependencies.git
    environment = dependencies.environment
    cache = PlanLockCache(worktreeRoot: root, sessionID: sessionID)
  }

  func commonDirectory() async throws(GitError) -> String {
    guard let cache else {
      record(
        "swiftgate: this session's id isn't one safe path component, so the plan-lock cache is "
          + "off and plan state is read fresh on every call.")
      return try await git.commonDirectory()
    }
    let git = self.git
    let answer = try await cache.commonDirectory(environment: environment) {
      () async throws(GitError) -> String in try await git.commonDirectory()
    }
    if let note = answer.note { record(note) }
    return answer.commonDirectory
  }

  /// Every distinct note, or `nil` when the cache behaved.
  var note: String? {
    let all = notes.withLock { $0 }
    return all.isEmpty ? nil : all.joined(separator: "\n")
  }

  private func record(_ note: String) {
    notes.withLock { if !$0.contains(note) { $0.append(note) } }
  }
}

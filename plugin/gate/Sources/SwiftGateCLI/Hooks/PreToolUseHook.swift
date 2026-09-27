import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// PreToolUse (spec §8): Bash and Edit/Write guards (< 50ms), and the advisory comment pass on
/// `git commit` (≤ 20s). A path a Bash command writes is judged exactly as a file tool's path.
enum PreToolUseHook {
  static let fileTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

  /// The JSON to print, or `nil` to leave the call to the normal permission flow.
  static func run(_ payload: HookPayload, root: URL, dependencies: HookDependencies) async
    -> String?
  {
    switch payload.toolName {
    case "Bash"?:
      guard let command = payload.command else { return nil }
      if let violation = BashGuard.evaluate(command) { return deny(violation) }
      if let violation = PlanCommandGuard.evaluate(
        command, sessionID: payload.sessionID, agentID: payload.agentID)
      {
        return deny(violation)
      }
      for path in writtenPaths(command, payload: payload, home: dependencies.environment["HOME"]) {
        if let violation = await writeViolation(
          path, payload: payload, root: root, dependencies: dependencies)
        {
          let reason = "this command writes `\(path)`. " + violation.reason
          return deny(GuardViolation(ruleID: violation.ruleID, reason: reason))
        }
      }
      guard BashGuard.isGitCommit(command) else { return nil }
      return await commitContext(root: root, dependencies: dependencies)
    case let tool? where fileTools.contains(tool):
      guard let path = payload.filePath else { return nil }
      return await writeViolation(path, payload: payload, root: root, dependencies: dependencies)
        .map(deny)
    default:
      return nil
    }
  }

  /// The paths a Bash command writes. A copy, move or link into a directory writes each source's
  /// name inside it, which only the filesystem can tell from a copy onto a new file's name.
  private static func writtenPaths(_ command: String, payload: HookPayload, home: String?)
    -> [String]
  {
    ShellSyntax.writeTargets(in: command).flatMap { target -> [String] in
      guard !target.entries.isEmpty,
        target.isDirectory
          || ToolPath.resolvedAbsolutes(target.path, cwd: payload.cwd, home: home)
            .contains(where: isDirectory)
      else { return [target.path] }
      return [target.path] + target.entries.map { target.path + "/" + $0 }
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
    _ path: String, payload: HookPayload, root: URL, dependencies: HookDependencies
  ) async -> GuardViolation? {
    let environmentValue = dependencies.environment[OrchestratorMarker.environmentVariable]
    let forms = ToolPath.resolvedForms(
      path, cwd: payload.cwd, home: dependencies.environment["HOME"])
    let orchestrator = OrchestratorMarker.isOrchestrator(
      environmentValue: environmentValue,
      lockContents: try? String(
        contentsOf: root.appending(path: OrchestratorMarker.lockFile), encoding: .utf8),
      sessionID: payload.sessionID, agentID: payload.agentID)
    for form in forms {
      if let violation = EditGuard.evaluate(path: form, isOrchestrator: orchestrator) {
        return violation
      }
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
        plans = await PlanLocks.records(root: root, git: dependencies.git)
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
          plans: await PlanLocks.records(root: root, git: dependencies.git),
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
      let file = try? PlanFileJSON.decode(Data(text.utf8)), !file.design.isEmpty
    else { return .unreadable }
    return .named(PlanLocks.resolve(design: file.design, root: root))
  }

  private static func deny(_ violation: GuardViolation) -> String {
    HookOutput.deny("swiftgate \(violation.ruleID): \(violation.reason)")
  }

  /// Runs on what is staged when the hook fires, so `git add … && git commit` in one command is
  /// checked by the git pre-commit hook rather than here. Advisory: it never denies the commit.
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
    return HookOutput.context(.preToolUse, sections.joined(separator: "\n\n"))
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
  static func records(root: URL, git: any Git) async -> [PlanStateGuard.PlanRecord] {
    guard let common = try? await git.commonDirectory(),
      let layout = try? PlanStateLayout(commonDirectory: common)
    else { return [] }
    let names = (try? FileManager.default.contentsOfDirectory(atPath: layout.root)) ?? []
    return names.sorted().compactMap { name in
      guard let plan = try? layout.plan(name) else { return nil }
      let design: PlanStateGuard.PlanRecord.Design
      if let data = FileManager.default.contents(atPath: plan.planFile),
        let file = try? PlanFileJSON.decode(data), !file.design.isEmpty
      {
        design = .named(resolve(design: file.design, root: root))
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

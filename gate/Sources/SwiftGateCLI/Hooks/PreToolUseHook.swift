import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// PreToolUse (spec §8): Bash and Edit/Write guards (< 50ms), and the advisory comment pass on
/// `git commit` (≤ 20s).
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
      guard BashGuard.isGitCommit(command) else { return nil }
      return await commitContext(root: root, dependencies: dependencies)
    case let tool? where fileTools.contains(tool):
      guard let path = payload.filePath else { return nil }
      return await fileGuard(path, payload: payload, root: root, dependencies: dependencies)
    default:
      return nil
    }
  }

  /// Every guard sees every spelling of the path the write could land on, so a relative,
  /// `..`-bearing or symlinked form is judged like the canonical one.
  private static func fileGuard(
    _ path: String, payload: HookPayload, root: URL, dependencies: HookDependencies
  ) async -> String? {
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
        return deny(violation)
      }
    }
    for form in forms {
      guard let target = PlanStateGuard.target(ofResolvedPath: form) else { continue }
      let locks = await PlanLocks.read(PlanStateGuard.lockScope(of: target), git: dependencies.git)
      if let violation = PlanStateGuard.evaluate(
        target, locks: locks, environmentValue: environmentValue, sessionID: payload.sessionID,
        agentID: payload.agentID)
      {
        return deny(violation)
      }
    }
    return nil
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
    var absolutes: [String] = []
    if path.hasPrefix("/") {
      absolutes.append(path)
    } else {
      absolutes.append(cwd + "/" + path)
      if let home, path.hasPrefix("~/") { absolutes.append(home + "/" + path.dropFirst(2)) }
    }
    var forms: [String] = [path]
    for absolute in absolutes {
      for form in [
        absolute, CanonicalPath.of(URL(filePath: absolute)), physical(absolute),
      ] where !forms.contains(form) {
        forms.append(form)
      }
    }
    return forms
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
  static func read(_ scope: PlanStateGuard.LockScope, git: any Git) async -> [String] {
    switch scope {
    case .none:
      return []
    case .plan(let plan):
      return contents(plan.orchestratorLock).map { [$0] } ?? []
    case .everyPlan(let layout):
      return every(layout)
    case .everyPlanInRepository:
      // No common dir means no lock can be found, so only the override can allow the write.
      guard let common = try? await git.commonDirectory(),
        let layout = try? PlanStateLayout(commonDirectory: common)
      else { return [] }
      return every(layout)
    }
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

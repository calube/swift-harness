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
      let orchestrator = OrchestratorMarker.isOrchestrator(
        environmentValue: dependencies.environment[OrchestratorMarker.environmentVariable],
        lockContents: try? String(
          contentsOf: root.appending(path: OrchestratorMarker.lockFile), encoding: .utf8),
        sessionID: payload.sessionID, agentID: payload.agentID)
      return EditGuard.evaluate(path: path, isOrchestrator: orchestrator).map(deny)
    default:
      return nil
    }
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

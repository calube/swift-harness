import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// What a hook invocation prints and how it exits. Decisions travel as JSON on stdout with exit 0;
/// exit 1 is Claude Code's non-blocking error, used only when the hook itself is broken.
struct HookResult: Sendable, Equatable {
  var stdout: String?
  var stderr: String?
  var exitCode: Int32

  static let silent = HookResult(stdout: nil, stderr: nil, exitCode: 0)

  static func output(_ json: String?) -> HookResult {
    HookResult(stdout: json, stderr: nil, exitCode: 0)
  }
}

/// Everything a hook touches outside the process, so every path runs from recorded payloads in
/// tests.
struct HookDependencies: Sendable {
  var git: any Git
  var swiftPM: any SwiftPM
  var formatter: any SwiftFormatter
  var xcode: any XcodeSelection
  var sweep: any OrphanCloneSweeping
  var commitJudge: any CommitCommentJudging
  var environment: [String: String]

  static func live(root: URL, environment: [String: String]) -> HookDependencies {
    let runner = LiveProcessRunner()
    return HookDependencies(
      git: LiveGit(runner: runner, repositoryRoot: root.path),
      swiftPM: ScopeResolution.liveSwiftPM(root: root),
      formatter: LiveSwiftFormatter(runner: runner, repositoryRoot: root.path),
      xcode: LiveXcodeSelection(
        runner: runner, developerDirectoryOverride: environment["DEVELOPER_DIR"]),
      sweep: PendingOrphanCloneSweep(), commitJudge: ConfiguredCommitCommentJudge.live,
      environment: environment)
  }
}

/// Removes simulator clones whose owning process died (spec §4.4). SessionStart calls it; the
/// simulator adapter that implements it lands separately, so until then there is nothing to sweep.
protocol OrphanCloneSweeping: Sendable {
  /// A line for session context when something was swept or could not be, else `nil`.
  func sweep() async -> String?
}

struct PendingOrphanCloneSweep: OrphanCloneSweeping {
  func sweep() async -> String? { nil }
}

/// The judge's comment questions on a Claude-authored commit (spec §7.5): advisory, cached by
/// content hash, run in an isolated reviewer. Answers nothing unless the repository enables the
/// judge.
protocol CommitCommentJudging: Sendable {
  /// Proposed trims for the staged comments, as context for Claude, or `nil`.
  func review(root: URL) async -> String?
}

struct DisabledCommitCommentJudge: CommitCommentJudging {
  func review(root: URL) async -> String? { nil }
}

/// Entry point for `swiftgate hook <event>`: decodes the payload, finds the project, and hands off
/// to the event's hook. Outside a project with `.swiftgate.toml` every hook is a silent no-op
/// that never builds its dependencies.
enum HookRunner {
  static func run(
    _ event: HookEvent, input: Data, dependencies: (URL) -> HookDependencies
  ) async -> HookResult {
    let payload: HookPayload
    do {
      payload = try HookPayload.decode(input)
    } catch {
      return HookResult(
        stdout: nil, stderr: "swiftgate hook \(event.rawValue): \(error)", exitCode: 1)
    }
    guard payload.hookEventName == event.claudeName else {
      return HookResult(
        stdout: nil,
        stderr:
          "swiftgate hook \(event.rawValue) received a \(payload.hookEventName) payload; check "
          + "hooks/hooks.json",
        exitCode: 1)
    }
    guard
      let root = ProjectRoot.locate(from: URL(filePath: payload.cwd, directoryHint: .isDirectory))
    else { return .silent }
    let dependencies = dependencies(root)
    switch event {
    case .sessionStart:
      return .output(await SessionStartHook.run(root: root, dependencies: dependencies))
    case .preToolUse:
      return .output(
        await PreToolUseHook.run(payload, root: root, dependencies: dependencies))
    case .postToolUse:
      return .output(
        await PostToolUseHook.run(payload, root: root, dependencies: dependencies))
    case .stop:
      return await StopHook.run(payload, root: root, dependencies: dependencies)
    }
  }
}

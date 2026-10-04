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
  /// Where each call's `hook.decision` goes, asked only after the hook has decided, so reading
  /// the config it needs never delays a decision; `nil` records none.
  var telemetry: @Sendable () -> HookTelemetry? = { nil }
  /// The `slice` tier a brownfield clone's Stop hook runs in the worktree: its verdict and report.
  var brownfieldSlice: @Sendable (URL) async -> (Verdict, String) = { root in
    await StopHook.sliceTier(root: root)
  }

  static func live(root: URL, environment: [String: String]) -> HookDependencies {
    let runner = LiveProcessRunner()
    return HookDependencies(
      git: LiveGit(runner: runner, repositoryRoot: root.path),
      swiftPM: ScopeResolution.liveSwiftPM(root: root),
      formatter: LiveSwiftFormatter(runner: runner, repositoryRoot: root.path),
      xcode: LiveXcodeSelection(
        runner: runner, developerDirectoryOverride: environment["DEVELOPER_DIR"]),
      sweep: ScratchWorktreeOrphanSweep(
        scratch: LiveScratchWorktrees(runner: runner, repositoryRoot: root.path)),
      commitJudge: ConfiguredCommitCommentJudge.live,
      environment: environment, telemetry: { HookTelemetry.live(root: root) })
  }
}

/// The project's event writer and the store identity whose salt hashes tool input.
struct HookTelemetry: Sendable {
  var events: any HarnessEventWriting
  /// Read only after the hook has decided; creates the store's identity on first use.
  var identity: @Sendable () throws(HarnessEventWriteError) -> EventStoreIdentity

  /// `nil` for a root with no loadable `.swiftgate.toml`, or with `[telemetry] enabled = false`,
  /// so neither writes anything, the store's identity included.
  static func live(root: URL) -> HookTelemetry? {
    guard case .success(let config?) = StaticCheckInputs.loadConfig(root: root) else { return nil }
    let events = EventWriterFactory.make(root: root, enabled: config.telemetry.enabled)
    guard !(events is DisabledEventWriter) else { return nil }
    return HookTelemetry(
      events: events,
      identity: { () throws(HarnessEventWriteError) in
        try EventSegmentStore(root: root).identity()
      })
  }

  /// Writes `hook.decision` for 1 call; a failure is the 1 line returned, never thrown.
  func record(
    _ event: HookEvent, payload: HookPayload, input: Data, result: HookResult, milliseconds: Int,
    at time: Date
  ) -> String? {
    do throws(HarnessEventWriteError) {
      let salt = try identity().salt
      let eventID = UUID().uuidString  // swiftgate:allow det.uuid-init — an id need only be unique
      let decision = HookDecisionEvent(
        event: event, tool: HookDecisionEvent.toolName(payload.toolName),
        decision: HookDecisionEvent.decision(stdout: result.stdout),
        ruleIDs: HookDecisionEvent.ruleIDs(stdout: result.stdout), milliseconds: milliseconds,
        sessionID: HookDecisionEvent.sessionID(payload.sessionID),
        inputHash: HookInputHash.of(payload: input, salt: salt))
      try events.append(
        HarnessEvent(
          eventID: eventID, time: time,
          source: HarnessEventSource(route: .hook, hook: HarnessHook(event)),
          payload: .hookDecision(decision)))
      return nil
    } catch {
      return "swiftgate: hook event not written: \(error)"
    }
  }
}

extension HarnessHook {
  init(_ event: HookEvent) {
    switch event {
    case .sessionStart: self = .sessionStart
    case .preToolUse: self = .preToolUse
    case .postToolUse: self = .postToolUse
    case .stop: self = .stop
    }
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

/// Removes `prove` and `mutate` scratch worktrees left registered by a run that was killed before
/// its cleanup, with whatever they hold (a whole checkout, often profile data).
struct ScratchWorktreeOrphanSweep: OrphanCloneSweeping {
  let scratch: LiveScratchWorktrees

  func sweep() async -> String? {
    let result: ScratchWorktreeSweep
    do throws(ScratchWorktreeError) {
      result = try await scratch.sweepRegisteredOrphans()
    } catch {
      return "Scratch worktree sweep could not list worktrees: \(error)"
    }
    var lines: [String] = []
    if !result.removed.isEmpty {
      lines.append(
        "Removed \(result.removed.count) scratch worktree(s) left by killed runs: "
          + result.removed.joined(separator: ", "))
    }
    if !result.failures.isEmpty {
      lines.append(
        "Could not remove \(result.failures.count) orphaned scratch worktree(s): "
          + result.failures.joined(separator: "; "))
    }
    return lines.isEmpty ? nil : lines.joined(separator: "\n")
  }
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
/// to the event's hook. Outside a project with `.swiftgate.toml` or a brownfield clone every hook
/// is a silent no-op that never builds its dependencies.
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
      let project = ProjectRoot.locateProfile(
        from: URL(filePath: payload.cwd, directoryHint: .isDirectory))
    else { return .silent }
    let root = project.root
    if case .brownfield = project, !brownfieldEvents.contains(event) { return .silent }
    let dependencies = dependencies(root)
    let clock = ContinuousClock()
    let start = clock.now
    var result = await dispatch(event, payload, project: project, dependencies: dependencies)
    let milliseconds = GateRun.milliseconds(clock.now - start)
    // The event follows the decision, and its failure is 1 line on stderr, which on exit 0 only
    // reaches the debug log: telemetry never delays or sways what the hook decided.
    if let telemetry = dependencies.telemetry(),
      let warning = telemetry.record(
        event, payload: payload, input: input, result: result, milliseconds: milliseconds,
        at: Date())
    {
      result.stderr = ([result.stderr].compactMap { $0 } + [warning]).joined(separator: "\n")
    }
    return result
  }

  /// The events a brownfield clone answers. Stop runs the owned `fast` tier, which that profile
  /// rejects, and PostToolUse formats Swift to this harness's style rather than the team's.
  static let brownfieldEvents: Set<HookEvent> = [.sessionStart, .preToolUse]

  private static func dispatch(
    _ event: HookEvent, _ payload: HookPayload, project: HookProject,
    dependencies: HookDependencies
  ) async -> HookResult {
    let root = project.root
    switch event {
    case .sessionStart:
      return .output(await SessionStartHook.run(payload, root: root, dependencies: dependencies))
    case .preToolUse:
      var brownfield: BrownfieldStateLayout?
      if case .brownfield(_, let layout) = project { brownfield = layout }
      return .output(
        await PreToolUseHook.run(
          payload, root: root, dependencies: dependencies, brownfield: brownfield))
    case .postToolUse:
      return .output(
        await PostToolUseHook.run(payload, root: root, dependencies: dependencies))
    case .stop:
      return await StopHook.run(payload, root: root, dependencies: dependencies)
    }
  }
}

import CryptoKit
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// Stop (spec §8, ≤ 90s): `check --tier fast`, or `slice` in a brownfield clone, blocking a RED
/// result under ``StopGate``'s policy.
enum StopHook {
  static let command = "hook stop"

  /// - Parameter brownfield: the worktree's clone runs the brownfield profile, so the hook gates
  ///   at `slice` instead of `fast`.
  static func run(
    _ payload: HookPayload, root: URL, dependencies: HookDependencies, brownfield: Bool = false
  ) async -> HookResult {
    let store = HookStateStore(worktreeRoot: root)
    let state = store.stopState(session: payload.sessionID)
    // A brownfield area can be in any language, so every changed path counts.
    let fingerprint = await ContentFingerprint.compute(
      git: dependencies.git, relevant: brownfield ? { _ in true } : ContentFingerprint.isRelevant)
    let reentry = payload.stopHookActive

    let outcome: StopGate.Outcome
    switch StopGate.plan(
      fingerprint: fingerprint, lastGreen: store.lastGreen(), state: state, reentry: reentry)
    {
    case .skip:
      return .silent
    case .reuseRed(let summary):
      outcome = StopGate.decide(
        verdict: .red, summary: summary, fingerprint: fingerprint, state: state, reentry: reentry)
    case .run:
      let (verdict, summary) =
        brownfield
        ? await dependencies.brownfieldSlice(root)
        : await fastTier(root: root, dependencies: dependencies)
      outcome = StopGate.decide(
        verdict: verdict, summary: summary, fingerprint: fingerprint, state: state,
        reentry: reentry)
    }

    var warnings: [String] = []
    do throws(HookStateError) {
      try store.saveStopState(outcome.state, session: payload.sessionID)
      if let green = outcome.lastGreen { try store.saveLastGreen(green) }
    } catch {
      // Lost state costs a re-run or a strike count restart, never a wrong verdict.
      warnings.append("swiftgate: could not save hook state: \(error)")
    }
    let stderr = warnings.isEmpty ? nil : warnings.joined(separator: "\n")

    switch outcome.decision {
    case .allow: return HookResult(stdout: nil, stderr: stderr, exitCode: 0)
    case .block(let reason):
      return HookResult(stdout: HookOutput.block(reason), stderr: stderr, exitCode: 0)
    case .release(let message), .warn(let message):
      return HookResult(stdout: HookOutput.systemMessage(message), stderr: stderr, exitCode: 0)
    }
  }

  /// The same run `swiftgate check --tier slice` performs, against the commit discovery read.
  static func sliceTier(root: URL) async -> (Verdict, String) {
    let clock = ContinuousClock()
    let start = clock.now
    let runID = RunID.make(startedAt: Date(), suffix: UInt32.random(in: .min ... .max))
    let runs = RunStore(worktreeRoot: root)
    let directory =
      (try? runs.runDirectory(for: runID))
      ?? FileManager.default.temporaryDirectory.appending(
        path: "swiftgate-\(runID)", directoryHint: .isDirectory)
    do {
      let context = GateRun.Context(runID: runID, directory: directory)
      let parts: GateRunParts
      do {
        let dependencies = try await BrownfieldSliceCheck.Dependencies.live(root: root)
        parts = try await BrownfieldSliceCheck.run(
          root: root, base: dependencies.config.brownfield.discoveredAt, context: context,
          dependencies: dependencies)
      } catch let error as BrownfieldCheckSetupError {
        parts = try BrownfieldCheck.notRun(.slice, because: error.reason)
      }
      let report = try RunReport(
        runID: runID, durationMilliseconds: GateRun.milliseconds(clock.now - start),
        tiers: parts.tiers, findings: parts.findings, allowances: parts.allowances)
      let telemetry = await GateRun.telemetry(root: root, events: nil, workingTree: nil)
      GateRun.record { () throws(RunStoreError) in
        try RunStore(worktreeRoot: root, events: telemetry.events).record(
          report, finishedAt: Date(), command: command, treeHash: telemetry.tree?.treeHash,
          dirty: telemetry.tree?.dirty, gateSteps: context.steps.steps, checkTier: .slice,
          testResults: context.tests.cases, baselineCount: parts.baselineCount)
      }
      return (report.verdict, ReportRenderer.human(report))
    } catch {
      return (.blocked, "swiftgate check --tier slice could not run: \(error)")
    }
  }

  /// The same run `swiftgate check --tier fast` performs, recorded in the run history under this
  /// hook's name so `stats` shows its latency against the stop-hook budget.
  static func fastTier(root: URL, dependencies: HookDependencies) async -> (Verdict, String) {
    let clock = ContinuousClock()
    let start = clock.now
    let startedAt = Date()
    let runID = RunID.make(startedAt: startedAt, suffix: UInt32.random(in: .min ... .max))
    let runs = RunStore(worktreeRoot: root)
    let directory =
      (try? runs.runDirectory(for: runID))
      ?? FileManager.default.temporaryDirectory.appending(
        path: "swiftgate-\(runID)", directoryHint: .isDirectory)
    do {
      let parts = try await CheckRun.run(
        root: root, tier: .fast, base: "origin/main",
        context: GateRun.Context(runID: runID, directory: directory),
        dependencies: CheckRun.Dependencies(
          root: root, swiftPM: dependencies.swiftPM, git: dependencies.git,
          formatter: dependencies.formatter))
      let report = try RunReport(
        runID: runID, durationMilliseconds: GateRun.milliseconds(clock.now - start),
        tiers: parts.tiers, findings: parts.findings, allowances: parts.allowances)
      try? runs.record(report, finishedAt: Date(), command: command)
      return (report.verdict, ReportRenderer.human(report))
    } catch {
      return (.blocked, "swiftgate check --tier fast could not run: \(error)")
    }
  }
}

/// Identifies the Swift-relevant content of a worktree: HEAD plus the current bytes of every
/// changed Swift source, manifest, lockfile and gate config. Equal fingerprints mean the fast tier
/// would judge the same content.
enum ContentFingerprint {
  static func isRelevant(_ path: String) -> Bool {
    let name = path.split(separator: "/").last.map(String.init) ?? path
    return path.hasSuffix(".swift") || name == "Package.resolved" || name == ConfigLoader.fileName
  }

  /// `nil` when git cannot say (no repository, no commit yet): the check then always runs.
  static func compute(
    git: any Git, relevant: (String) -> Bool = ContentFingerprint.isRelevant
  ) async -> String? {
    do throws(GitError) {
      guard let head = try await git.revision("HEAD") else { return nil }
      let prefix = try await git.workingDirectoryPrefix()
      let changed = try await git.changedFiles(since: "HEAD")
        .filter { $0.hasPrefix(prefix) && relevant($0) }
        .map { String($0.dropFirst(prefix.count)) }
      let hashes = try await git.contentHashes(of: changed)
      var hasher = SHA256()
      hasher.update(data: Data("\(head)\n\(prefix)\n".utf8))
      for path in changed.sorted() {
        hasher.update(data: Data("\(path)\0\(hashes[path] ?? "deleted")\n".utf8))
      }
      return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    } catch {
      return nil
    }
  }
}

import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateRules

/// Why `plan surface` refused a surface it could judge. Each is exit 1 and writes nothing.
enum PlanSurfaceRule: String, Sendable, Equatable, CaseIterable {
  /// The plan's spec page has no confirmation, or its bytes moved since the confirm.
  case notConfirmed = "plan-surface.not-confirmed"
  /// The surface's parent isn't `main`'s HEAD, so `main` can't fast-forward to it.
  case notOnMain = "plan-surface.not-on-main"
  /// `surface-check` found behaviour in the surface.
  case behaviour = "plan-surface.behaviour"
  /// The gate run id isn't in this checkout's run history.
  case gateUnknown = "plan-surface.gate-unknown"
  /// The gate run is RED or BLOCKED.
  case gateRed = "plan-surface.gate-red"
  /// The gate run ran at another commit than the surface.
  case gateStale = "plan-surface.gate-stale"
  /// The gate run's tier is below the preset's `merge_gate`.
  case gateTier = "plan-surface.gate-tier"
  /// A worktree has `main` checked out, whose files a moved ref would leave behind.
  case mainCheckedOut = "plan-surface.main-checked-out"
  /// The plan already records a surface; a plan has 1.
  case alreadyRecorded = "plan-surface.already-recorded"
}

/// What `plan surface` did to a spec-page plan's surface.
struct PlanSurfaceReport: Sendable, Equatable, Encodable {
  enum Status: String, Sendable, Encodable {
    case recorded
    case refused
    /// The lock is free or another session holds it; nothing was written.
    case notHeld = "not-held"
    case blocked
  }

  var plan: String
  var status: Status = .blocked
  var verdict: Verdict = .blocked
  var rule: PlanSurfaceRule?
  /// The session holding the lock when it isn't the caller.
  var holder: String?
  /// The surface's full sha, once resolved.
  var surfaceCommit: String?
  var gate: String?
  /// The preset's `merge_gate`, once the preset is known.
  var mergeGate: CheckTier?
  var findings: [Finding] = []
  var message = ""

  private enum CodingKeys: String, CodingKey {
    case command, plan, status, verdict, rule, holder, surfaceCommit, gate, mergeGate, findings
    case message
  }

  /// Every key is always present; an absent value is `null`.
  func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(PlanSurfaceRun.command, forKey: .command)
    try c.encode(plan, forKey: .plan)
    try c.encode(status, forKey: .status)
    try c.encode(verdict, forKey: .verdict)
    try c.encode(rule?.rawValue, forKey: .rule)
    try c.encode(holder, forKey: .holder)
    try c.encode(surfaceCommit, forKey: .surfaceCommit)
    try c.encode(gate, forKey: .gate)
    try c.encode(mergeGate?.rawValue, forKey: .mergeGate)
    try c.encode(findings, forKey: .findings)
    try c.encode(message, forKey: .message)
  }
}

/// The checkout and adapters `plan surface` acts on.
struct PlanSurfaceContext: Sendable {
  /// The checkout the command runs in: its run history holds the gate run.
  let root: URL
  let git: any Git
  let branches: any SprintBranches
  let surfaceReader: any SurfaceCommitReading
  /// `.swiftgate.toml`'s `[build.presets]`.
  var presets: [String: BuildPreset] = [:]
}

/// The testable core of `plan surface` (fast modes §5.1 step 2, §6): the lock holder of a
/// confirmed spec-page plan lands its 1 surface on `main` by fast-forward, once `surface-check`
/// and the preset's merge gate have passed at exactly that commit, and records it in plan.json.
enum PlanSurfaceRun {
  static let command = "plan surface"
  static let mainBranch = "main"

  /// A refusal (exit 1) or a blocked read (exit 2), thrown out of the checks as the report.
  private struct Stop: Error {
    let report: PlanSurfaceReport
  }

  static func run(
    slug: String, commit: String, gate: String, session: String?, context: PlanSurfaceContext
  ) async -> PlanSurfaceReport {
    await run(
      slug: slug, commit: commit, gate: gate, session: session, preset: "", context: context)
  }

  static func run(
    slug: String, commit: String, gate: String, session: String?, preset: String,
    context: PlanSurfaceContext
  ) async -> PlanSurfaceReport {
    var report = PlanSurfaceReport(plan: slug, gate: gate)
    do throws(Stop) {
      try await land(
        &report, slug: slug, commit: commit, gate: gate, session: session, presetName: preset,
        context: context)
    } catch {
      return error.report
    }
    return report
  }

  private static func land(
    _ report: inout PlanSurfaceReport, slug: String, commit: String, gate: String,
    session: String?, presetName: String, context: PlanSurfaceContext
  ) async throws(Stop) {
    guard let preset = context.presets[presetName] else {
      let known = context.presets.keys.sorted().joined(separator: ", ")
      throw blocked(
        report,
        "preset `\(presetName)` isn't defined in .swiftgate.toml; known presets: "
          + (known.isEmpty ? "none" : known))
    }
    report.mergeGate = preset.mergeGate
    guard let session else {
      throw blocked(report, "--session is required: pass the id from the SessionStart context")
    }
    guard PlanLock.isValidSession(session) else {
      throw blocked(report, "--session must be a non-empty id without whitespace")
    }
    guard !gate.isEmpty, RunID.isValid(gate) else {
      throw blocked(
        report, "--gate `\(gate)` isn't a run id; pass the id `swiftgate check` printed")
    }

    let store: PlanStateStore
    do {
      let common = try await context.git.commonDirectory()
      store = PlanStateStore(plan: try PlanStateLayout(commonDirectory: common).plan(slug))
    } catch let error as GitError {
      throw blocked(report, "can't find the git common dir: \(error)")
    } catch {
      throw blocked(report, "invalid plan name `\(slug)`: \(error)")
    }
    let holder: String?
    do {
      holder = try PlanLock(plan: store.plan).holder()
    } catch {
      throw blocked(report, "can't read \(store.plan.orchestratorLock): \(error)")
    }
    guard let holder, holder == session else {
      var notHeld = report
      notHeld.status = .notHeld
      notHeld.verdict = .red
      notHeld.holder = holder
      notHeld.message =
        holder.map { PlanLockRun.heldByOtherMessage(slug, $0) }
        ?? "plan `\(slug)` isn't claimed; only the session holding its lock lands its surface. "
        + "Claim it with `swiftgate plan claim \(slug) --spec-page --session <id>` first."
      throw Stop(report: notHeld)
    }

    let current: PlanFile
    do {
      current = try store.planFile()
    } catch {
      throw blocked(report, "\(store.plan.planFile) can't be read or decoded: \(error)")
    }
    let page: PlanFile.SpecPageSource
    switch current.source {
    case .design(let design):
      throw blocked(
        report,
        "plan `\(slug)` is a design plan (its design is \(design.design)); only a spec-page plan "
          + "lands its surface with plan surface, and plan.json was left as it is")
    case .specPage(let source):
      page = source
    }
    if let recorded = current.surfaceCommit {
      throw refused(
        report, .alreadyRecorded,
        "plan `\(slug)` already records surface \(recorded); a plan has 1 surface. A task that "
          + "needs more API commits it as its own stub")
    }
    try requireConfirmed(report, page, store: store, slug: slug)

    let sha = try await git(report, "resolving \(commit)") { () throws(GitError) in
      try await context.git.revision(commit)
    }
    guard let sha else { throw blocked(report, "`\(commit)` names no commit") }
    report.surfaceCommit = sha
    let main = try await git(report, "reading \(mainBranch)") { () throws(GitError) in
      try await context.git.revision("refs/heads/\(mainBranch)")
    }
    guard let main else {
      throw blocked(report, "this repository has no `\(mainBranch)` branch to land the surface on")
    }
    // `main` already at the surface is a run that moved it and stopped before recording.
    let landed = main == sha
    if !landed {
      let parent = try await git(report, "reading \(sha)'s parent") { () throws(GitError) in
        try await context.git.revision(sha + "^")
      }
      guard parent == main else {
        throw refused(
          report, .notOnMain,
          "the surface \(sha) must sit directly on \(mainBranch)'s HEAD \(main), but its parent is "
            + (parent ?? "none")
            + ". Cut surface/<slug> from \(mainBranch), commit the surface alone, and re-run its "
            + "merge gate")
      }
    }

    try await requireNoBehaviour(&report, sha, context)
    try requireGate(report, gate, at: sha, mergeGate: preset.mergeGate, context)

    if !landed {
      let checkedOut = try await workspace(report, "listing worktrees") {
        () throws(GitWorkspaceError) in
        try await context.branches.checkedOutBranches()
      }
      if checkedOut.contains(mainBranch) {
        throw refused(
          report, .mainCheckedOut,
          "\(mainBranch) is checked out in a worktree, whose files a moved ref would leave "
            + "behind; switch that checkout off \(mainBranch) and re-run")
      }
      let moved = try await workspace(report, "fast-forwarding \(mainBranch)") {
        () throws(GitWorkspaceError) in
        try await context.branches.fastForward(mainBranch, from: main, to: sha)
      }
      guard moved else {
        throw refused(
          report, .notOnMain,
          "\(sha) doesn't descend from \(mainBranch) at \(main), so \(mainBranch) can't "
            + "fast-forward to it; plan surface never merges or rebases")
      }
    }

    let updated = PlanFile(
      schemaVersion: current.schemaVersion, slug: current.slug, source: current.source,
      surfaceCommit: sha, resume: current.resume)
    do {
      // Written beside the old file and renamed over it: a reader sees one whole file or the other.
      try PlanFileJSON.encode(updated).write(
        to: URL(filePath: store.plan.planFile), options: .atomic)
    } catch {
      throw blocked(
        report,
        "\(mainBranch) is at \(sha), but writing \(store.plan.planFile) failed: \(error). Re-run "
          + "the same command to record it")
    }
    report.status = .recorded
    report.verdict = .green
    report.message =
      "fast-forwarded \(mainBranch) to surface \(sha) and recorded it for plan `\(slug)`"
  }

  /// The page is confirmed, and its bytes still hash to the sha the confirm recorded.
  private static func requireConfirmed(
    _ report: PlanSurfaceReport, _ page: PlanFile.SpecPageSource, store: PlanStateStore,
    slug: String
  ) throws(Stop) {
    let confirmAgain =
      "Confirm it with `swiftgate plan confirm \(slug) --by user|spec-quotes --spec <file> "
      + "--session <id>` first"
    guard let approval = page.approval else {
      throw refused(
        report, .notConfirmed, "plan `\(slug)`'s spec page isn't confirmed. \(confirmAgain)")
    }
    let path = store.specPageFile(page)
    let data: Data
    do {
      data = try Data(contentsOf: URL(filePath: path))
    } catch {
      throw blocked(report, "can't read the spec page \(path): \(error.localizedDescription)")
    }
    let sha = SpecPageCheck.pageSha(data)
    guard sha == approval.pageSha else {
      throw refused(
        report, .notConfirmed,
        "the spec page \(path) hashes to \(sha), not the \(approval.pageSha) its confirm "
          + "recorded: it changed after the confirm. \(confirmAgain)")
    }
  }

  private static func requireNoBehaviour(
    _ report: inout PlanSurfaceReport, _ sha: String, _ context: PlanSurfaceContext
  ) async throws(Stop) {
    switch await SurfaceCheckRun.outcome(commit: sha, reader: context.surfaceReader) {
    case .blocked(let reason), .invalid(let reason, _):
      throw blocked(report, reason)
    case .checked(let result):
      let findings = result.findings.filter { $0.ruleID != SurfaceCheck.summaryRuleID }
      guard !findings.isEmpty else { return }
      report.findings = findings
      let listed = findings.map { finding in
        "\(finding.file)\(finding.line.map { ":\($0)" } ?? ""): \(finding.message)"
      }
      throw refused(
        report, .behaviour,
        "surface-check found behaviour in \(sha): \(listed.joined(separator: "; ")). Move the "
          + "behaviour to a task, rewrite the surface commit and re-run its merge gate")
    }
  }

  /// The run is in this checkout's history, GREEN, at `mergeGate` or above, and ran at `sha`.
  private static func requireGate(
    _ report: PlanSurfaceReport, _ id: String, at sha: String, mergeGate: CheckTier,
    _ context: PlanSurfaceContext
  ) throws(Stop) {
    let runs = RunStore(worktreeRoot: context.root)
    let history: (records: [RunHistoryRecord], invalidLines: Int)
    do {
      history = try runs.readHistory()
    } catch {
      throw blocked(report, "reading \(runs.historyFile.path): \(error); fix or move it and re-run")
    }
    guard let record = history.records.last(where: { $0.runID == id }) else {
      let skipped =
        history.invalidLines > 0 ? " (\(history.invalidLines) unreadable lines skipped)" : ""
      throw refused(
        report, .gateUnknown,
        "run \(id) isn't in \(runs.historyFile.path)\(skipped); run the merge gate in this "
          + "checkout and pass the id `swiftgate check` printed")
    }
    let rerun = "`swiftgate check --tier \(mergeGate.rawValue)` at \(sha)"
    let tier = TaskReturnEvidence.GateRun.tier(ofCommand: record.command)
    guard let tier, TaskReturnCheck.covers(tier, mergeGate) else {
      throw refused(
        report, .gateTier,
        "run \(id) was `\(record.command ?? "an unnamed command")`, below the preset's merge_gate "
          + "`\(mergeGate.rawValue)`; run \(rerun) and pass its id")
    }
    guard record.verdict == .green else {
      throw refused(
        report, .gateRed,
        "run \(id) is \(record.verdict.rawValue); fix what it found and run \(rerun)")
    }
    guard record.headCommit == sha else {
      throw refused(
        report, .gateStale,
        "run \(id) ran at \(record.headCommit ?? "an unrecorded commit"), not the surface \(sha); "
          + "run \(rerun) and pass its id")
    }
  }

  private static func git<T>(
    _ report: PlanSurfaceReport, _ what: String, _ body: () async throws(GitError) -> T
  ) async throws(Stop) -> T {
    do {
      return try await body()
    } catch {
      throw blocked(report, "git failed \(what): \(error)")
    }
  }

  private static func workspace<T>(
    _ report: PlanSurfaceReport, _ what: String,
    _ body: () async throws(GitWorkspaceError) -> T
  ) async throws(Stop) -> T {
    do {
      return try await body()
    } catch {
      throw blocked(report, "git failed \(what): \(error)")
    }
  }

  private static func refused(
    _ report: PlanSurfaceReport, _ rule: PlanSurfaceRule, _ message: String
  ) -> Stop {
    var refused = report
    refused.status = .refused
    refused.verdict = .red
    refused.rule = rule
    refused.message = message
    return Stop(report: refused)
  }

  private static func blocked(_ report: PlanSurfaceReport, _ message: String) -> Stop {
    var blocked = report
    blocked.status = .blocked
    blocked.verdict = .blocked
    blocked.rule = nil
    blocked.message = message
    return Stop(report: blocked)
  }

  static func render(_ report: PlanSurfaceReport, format: OutputFormat) -> String {
    switch format {
    case .json:
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      let data = (try? encoder.encode(report)) ?? Data()
      return String(decoding: data, as: UTF8.self)
    case .human:
      let rule = report.rule.map { "\($0.rawValue) " } ?? ""
      return "\(command): \(report.verdict.rawValue) \(rule)\(report.message)"
    }
  }
}

struct PlanSurfaceCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "surface",
    abstract: "Land a spec-page plan's surface commit on main and record it, as its lock holder.",
    discussion:
      "The surface's parent must be main's HEAD, surface-check must find no behaviour in it, "
      + "and --gate must name a GREEN run in this checkout's history at the preset's merge_gate "
      + "tier or above whose HEAD was the surface. Then main fast-forwards to the surface "
      + "(never a merge or rebase) and plan.json records it as surfaceCommit. A refusal exits 1 "
      + "as plan-surface.<reason> and writes nothing: not-confirmed, not-on-main, behaviour, "
      + "gate-unknown, gate-red, gate-stale, gate-tier, main-checked-out or already-recorded; "
      + "so does a session without the plan's lock. A missing or invalid flag, an unknown "
      + "preset or commit, a design plan, or state, history or git that can't be read exits 2.")

  @Argument(help: "The plan's slug.")
  var slug: String

  @Argument(help: "The surface commit.")
  var commit: String

  @Option(help: "The merge gate run's id, as `check` printed it in this checkout.")
  var gate: String

  @Option(help: "The build preset whose merge_gate the run must reach.")
  var preset: String

  @Option(help: "The session id holding the plan's lock (from the SessionStart context).")
  var session: String?

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let runner = LiveProcessRunner()
    let report: PlanSurfaceReport
    do {
      let presets = try ConfigLoader().load(repositoryRoot: root)?.buildPresets ?? [:]
      report = await PlanSurfaceRun.run(
        slug: slug, commit: commit, gate: gate, session: session, preset: preset,
        context: PlanSurfaceContext(
          root: root, git: LiveGit(runner: runner, repositoryRoot: root.path),
          branches: LiveSprintBranches(runner: runner, repositoryRoot: root.path),
          surfaceReader: LiveSurfaceCommitReader(runner: runner, repositoryRoot: root.path),
          presets: presets))
    } catch {
      report = PlanSurfaceReport(
        plan: slug, gate: gate, message: "can't load .swiftgate.toml: \(error)")
    }
    Console.write(PlanSurfaceRun.render(report, format: output.format))
    if report.verdict != .green { throw ExitCode(report.verdict.exitCode) }
  }
}

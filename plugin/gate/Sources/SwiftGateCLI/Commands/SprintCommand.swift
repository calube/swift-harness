import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateRules

/// Why a `swiftgate sprint` command refused. Each id names what to do next in its message.
enum SprintRefusal: String, CaseIterable, Sendable {
  case outOfOrder = "sprint.out-of-order"
  case invalidSlug = "sprint.invalid-slug"
  case invalidSpecPage = "sprint.invalid-spec-page"
  case invalidCommit = "sprint.invalid-commit"
  case invalidGateRun = "sprint.invalid-gate-run"
  case invalidSliceCount = "sprint.invalid-slice-count"
  case specPageMissing = "sprint.spec-page-missing"
  case mainNotGreen = "sprint.main-not-green"
  case branchExists = "sprint.branch-exists"
  case wrongBranch = "sprint.wrong-branch"
  case surfaceOffBranch = "sprint.surface-off-branch"
  case surfaceBehaviour = "sprint.surface-behaviour"
  case surfaceUnreadable = "sprint.surface-unreadable"
  case gateUnknown = "sprint.gate-unknown"
  case gateTier = "sprint.gate-tier"
  case gateNotReady = "sprint.gate-not-ready"
  case gateRed = "sprint.gate-red"
  case gateBlocked = "sprint.gate-blocked"
  case gateStale = "sprint.gate-stale"
  case gateProofBase = "sprint.gate-proof-base"
  case gateBase = "sprint.gate-base"
  case mainMoved = "sprint.main-moved"
  case notFastForward = "sprint.not-fast-forward"
  case mainCheckedOut = "sprint.main-checked-out"
  case historyUnreadable = "sprint.history-unreadable"
  case stateMalformed = "sprint.state-malformed"
  case stateLocked = "sprint.state-locked"
  case stateIO = "sprint.state-io"
  case commonDirectory = "sprint.common-directory"
  case git = "sprint.git"

  /// RED for a refusal the caller fixes; BLOCKED when the state, history or git couldn't be read.
  var verdict: Verdict {
    switch self {
    case .surfaceUnreadable, .historyUnreadable, .stateMalformed, .stateLocked, .stateIO,
      .commonDirectory, .git:
      .blocked
    default:
      .red
    }
  }
}

/// What 1 sprint command did, or why it refused.
struct SprintOutcome: Sendable, Equatable {
  let command: String
  /// `nil` when the command did what it was asked.
  let refusal: SprintRefusal?
  let message: String
  /// The recorded run after the command: the new one, or the unchanged one it refused on.
  let run: SprintRun?

  var verdict: Verdict { refusal?.verdict ?? .green }
}

/// The checkout and plan state a sprint command acts on.
struct SprintContext: Sendable {
  /// The checkout the command runs in: its run history holds the gate runs a command reads.
  let root: URL
  let git: any Git
  let branches: any SprintBranches
  let store: SprintStore
  let surfaceReader: any SurfaceCommitReading
}

/// Fast modes §4: each sprint step is a command that checks it before the state machine records it.
/// Gate runs are read from this checkout's run history by id, never taken from the caller.
enum SprintCommandRun {
  static let mainBranch = "main"

  private struct Refused: Error {
    let refusal: SprintRefusal
    let message: String

    init(_ refusal: SprintRefusal, _ message: String) {
      self.refusal = refusal
      self.message = message
    }
  }

  static func start(slug: String, specPage: String, slices: Int, context: SprintContext) async
    -> SprintOutcome
  {
    await outcome("sprint start", context) { current throws(Refused) in
      try expect(.start, current)
      let base = try await git("reading main") { () throws(GitError) in
        try await context.git.revision("refs/heads/\(mainBranch)")
      }
      guard let base else {
        throw Refused(.mainNotGreen, "this repository has no `\(mainBranch)` branch to start from")
      }
      _ = try transition(
        .start(slug: slug, specPage: specPage, baseCommit: base, sliceCount: slices), current)
      var isDirectory: ObjCBool = false
      let page = specPage.hasPrefix("/") ? specPage : context.root.appending(path: specPage).path
      guard FileManager.default.fileExists(atPath: page, isDirectory: &isDirectory),
        !isDirectory.boolValue
      else {
        throw Refused(
          .specPageMissing, "spec page \(specPage) doesn't exist; write the spec page first")
      }
      try requireGreenMain(base, context)
      let branch = "sprint/" + slug
      let existing = try await git("reading \(branch)") { () throws(GitError) in
        try await context.git.revision("refs/heads/\(branch)")
      }
      if existing != nil {
        throw Refused(
          .branchExists, "branch \(branch) already exists; delete it or pick another slug")
      }
      try await workspace("creating \(branch)") { () throws(GitWorkspaceError) in
        try await context.branches.createBranch(branch, at: base)
      }
      let run: SprintRun
      do throws(Refused) {
        run = try await apply(
          .start(slug: slug, specPage: specPage, baseCommit: base, sliceCount: slices), context)
      } catch {
        try? await context.branches.deleteBranch(branch, at: base)
        throw error
      }
      return (
        run,
        "started sprint `\(slug)` on \(branch) at \(base); run `git switch \(branch)`, commit "
          + "the surface, then `swiftgate sprint surface <sha>`"
      )
    }
  }

  static func surface(commit: String, context: SprintContext) async -> SprintOutcome {
    await outcome("sprint surface", context) { current throws(Refused) in
      try expect(.surface, current)
      guard let current else { throw Refused(.outOfOrder, "no sprint is recorded") }
      try await requireBranch(current, context)
      let resolved = try await git("resolving \(commit)") { () throws(GitError) in
        try await context.git.revision(commit)
      }
      guard let sha = resolved else {
        throw Refused(.invalidCommit, "`\(commit)` names no commit")
      }
      let parent = try await git("reading \(sha)'s parent") { () throws(GitError) in
        try await context.git.revision(sha + "^")
      }
      let onBranch = try await git("checking \(sha) is on \(current.branch)") {
        () throws(GitError) in
        try await context.git.isAncestor(sha, of: "refs/heads/\(current.branch)")
      }
      guard parent == current.baseCommit, onBranch else {
        throw Refused(
          .surfaceOffBranch,
          "the surface must be the first commit on \(current.branch) after its base "
            + "\(current.baseCommit); \(sha) is "
            + (onBranch ? "not the first" : "not on \(current.branch)")
            + ". Put the surface first on the branch and re-run")
      }
      switch await SurfaceCheckRun.outcome(commit: sha, reader: context.surfaceReader) {
      case .blocked(let reason), .invalid(let reason, _):
        throw Refused(.surfaceUnreadable, reason)
      case .checked(let result):
        let findings = result.findings.filter { $0.ruleID != SurfaceCheck.summaryRuleID }
        if !findings.isEmpty {
          let listed = findings.map { finding in
            "\(finding.file)\(finding.line.map { ":\($0)" } ?? ""): \(finding.message)"
          }
          throw Refused(
            .surfaceBehaviour,
            "surface-check found behaviour in \(sha): \(listed.joined(separator: "; ")). Move "
              + "the behaviour to a slice, rewrite the surface commit and re-run")
        }
      }
      let run = try await apply(.surface(commit: sha), context)
      return (run, "recorded surface \(sha); write slice 1's failing test next")
    }
  }

  static func slice(_ number: Int, gate: String, context: SprintContext) async -> SprintOutcome {
    await outcome("sprint slice", context) { current throws(Refused) in
      try expect(.slice(number), current)
      guard let current else { throw Refused(.outOfOrder, "no sprint is recorded") }
      try await requireBranch(current, context)
      let record = try gateRun(gate, context)
      let tier = TaskReturnEvidence.GateRun.tier(ofCommand: record.command)
      guard let tier, TaskReturnCheck.covers(tier, .push) else {
        throw Refused(
          .gateTier,
          "run \(gate) was `\(record.command ?? "an unnamed command")`; a slice needs "
            + "`swiftgate check --tier push` or above at HEAD")
      }
      let head = try await branchHead(current, context)
      try requireGreen(record, at: head, current)
      try requireSurfaceBase(record, current)
      let run = try await apply(.slice(number, gateRun: gate), context)
      return (run, "slice \(number) passed at \(head) with \(tier.rawValue) run \(gate)")
    }
  }

  static func finish(gate: String, context: SprintContext) async -> SprintOutcome {
    await outcome("sprint finish", context) { current throws(Refused) in
      try expect(.finish, current)
      guard let current, let surface = current.surfaceCommit else {
        throw Refused(.outOfOrder, "no surfaced sprint is recorded")
      }
      try await requireBranch(current, context)
      let record = try gateRun(gate, context)
      guard TaskReturnEvidence.GateRun.tier(ofCommand: record.command) == .ready else {
        throw Refused(
          .gateNotReady,
          "run \(gate) was `\(record.command ?? "an unnamed command")`; finish needs "
            + "`swiftgate check --tier ready --base \(mainBranch) --proof-base \(surface)` at HEAD")
      }
      let head = try await branchHead(current, context)
      try requireGreen(record, at: head, current)
      guard (record.proofBases ?? []).contains(where: { names($0, surface) }) else {
        let bases = record.proofBases ?? []
        throw Refused(
          .gateProofBase,
          "run \(gate) proved at "
            + (bases.isEmpty ? "no proof base" : bases.joined(separator: ", "))
            + ", not the sprint's surface \(surface); re-run `swiftgate check --tier ready --base "
            + "\(mainBranch) --proof-base \(surface)`")
      }
      let main = try await git("reading \(mainBranch)") { () throws(GitError) in
        try await context.git.revision("refs/heads/\(mainBranch)")
      }
      // `main` already at HEAD is a finish that moved it and stopped before recording.
      if main != head {
        guard main == current.baseCommit else {
          throw Refused(
            .mainMoved,
            "\(mainBranch) is at \(main ?? "nothing"), not \(current.baseCommit) where this sprint "
              + "started; finish never merges or rebases. Start a new sprint from "
              + "\(mainBranch) and carry the work over")
        }
        let checkedOut = try await workspace("listing worktrees") { () throws(GitWorkspaceError) in
          try await context.branches.checkedOutBranches()
        }
        if checkedOut.contains(mainBranch) {
          throw Refused(
            .mainCheckedOut,
            "\(mainBranch) is checked out in a worktree, whose files a moved ref would leave "
              + "behind; switch that checkout off \(mainBranch) and re-run")
        }
        let moved = try await workspace("fast-forwarding \(mainBranch)") {
          () throws(GitWorkspaceError) in
          try await context.branches.fastForward(mainBranch, from: current.baseCommit, to: head)
        }
        guard moved else {
          throw Refused(
            .notFastForward,
            "\(current.branch) at \(head) doesn't descend from \(current.baseCommit), so "
              + "\(mainBranch) can't fast-forward to it; finish never merges or rebases")
        }
      }
      let run = try await apply(.finish(gateRun: gate), context)
      return (run, "fast-forwarded \(mainBranch) to \(head); the sprint is finished")
    }
  }

  static func status(context: SprintContext) async -> SprintOutcome {
    await outcome("sprint status", context) { current throws(Refused) in
      guard let current else {
        return (nil, "no sprint is recorded; start one")
      }
      return (current, "sprint `\(current.slug)` on \(current.branch): \(describe(current))")
    }
  }

  // MARK: - checks

  private static func outcome(
    _ command: String, _ context: SprintContext,
    _ body: (SprintRun?) async throws(Refused) -> (SprintRun?, String)
  ) async -> SprintOutcome {
    let current: SprintRun?
    do {
      current = try context.store.read()
    } catch {
      let refused = refusal(error)
      return SprintOutcome(
        command: command, refusal: refused.refusal, message: refused.message, run: nil)
    }
    do {
      let (run, message) = try await body(current)
      return SprintOutcome(command: command, refusal: nil, message: message, run: run)
    } catch {
      return SprintOutcome(
        command: command, refusal: error.refusal, message: error.message, run: current)
    }
  }

  private static func expect(_ step: SprintNextStep, _ current: SprintRun?) throws(Refused) {
    let expected = current?.next ?? .start
    guard step == expected else {
      throw refusal(SprintTransitionError.outOfOrder(attempted: step, expected: expected))
    }
  }

  private static func transition(_ event: SprintEvent, _ current: SprintRun?)
    throws(Refused) -> SprintRun
  {
    do {
      return try SprintTransition.apply(event, to: current)
    } catch {
      throw refusal(error)
    }
  }

  private static func apply(_ event: SprintEvent, _ context: SprintContext)
    async throws(Refused) -> SprintRun
  {
    do {
      return try await context.store.apply(event)
    } catch {
      throw refusal(error)
    }
  }

  /// A sprint's commands act only from a checkout on its own branch.
  private static func requireBranch(_ run: SprintRun, _ context: SprintContext)
    async throws(Refused)
  {
    let branch = try await workspace("reading the current branch") {
      () throws(GitWorkspaceError) in
      try await context.branches.currentBranch()
    }
    guard branch == run.branch else {
      throw Refused(
        .wrongBranch,
        "this checkout is on \(branch ?? "a detached HEAD"), but the recorded sprint "
          + "`\(run.slug)` runs on \(run.branch); run `git switch \(run.branch)`, or finish that "
          + "sprint before starting another")
    }
  }

  private static func branchHead(_ run: SprintRun, _ context: SprintContext)
    async throws(Refused) -> String
  {
    let head = try await git("reading \(run.branch)") { () throws(GitError) in
      try await context.git.revision("refs/heads/\(run.branch)")
    }
    guard let head else {
      throw Refused(.wrongBranch, "branch \(run.branch) no longer exists")
    }
    return head
  }

  private static func gateRun(_ id: String, _ context: SprintContext) throws(Refused)
    -> RunHistoryRecord
  {
    guard !id.isEmpty, RunID.isValid(id) else {
      throw refusal(SprintTransitionError.invalidGateRun(id))
    }
    let runs = RunStore(worktreeRoot: context.root)
    let history: (records: [RunHistoryRecord], invalidLines: Int)
    do {
      history = try runs.readHistory()
    } catch {
      throw Refused(
        .historyUnreadable, "reading \(runs.historyFile.path): \(error); fix or move it and re-run")
    }
    guard let record = history.records.last(where: { $0.runID == id }) else {
      let skipped =
        history.invalidLines > 0 ? " (\(history.invalidLines) unreadable lines skipped)" : ""
      throw Refused(
        .gateUnknown,
        "run \(id) isn't in \(runs.historyFile.path)\(skipped); pass the id `swiftgate check` "
          + "printed in this checkout")
    }
    return record
  }

  /// The run is GREEN and ran at `head`.
  private static func requireGreen(_ record: RunHistoryRecord, at head: String, _ run: SprintRun)
    throws(Refused)
  {
    switch record.verdict {
    case .green: break
    case .red:
      throw Refused(
        .gateRed, "run \(record.runID) is RED; fix what it found and re-run the gate at HEAD")
    case .blocked:
      throw Refused(
        .gateBlocked,
        "run \(record.runID) is BLOCKED; fix the environment it names and re-run the gate at HEAD")
    }
    guard record.headCommit == head else {
      throw Refused(
        .gateStale,
        "run \(record.runID) ran at \(record.headCommit ?? "an unrecorded commit"), but "
          + "\(run.branch) is at \(head); re-run the gate at HEAD and pass its id")
    }
  }

  /// A slice's diff is measured from the surface, so a stub a later slice fills isn't judged
  /// uncovered in this one. `finish` measures from `main`, covering the whole sprint once.
  private static func requireSurfaceBase(_ record: RunHistoryRecord, _ run: SprintRun)
    throws(Refused)
  {
    guard let surface = run.surfaceCommit else {
      throw Refused(.outOfOrder, "no surface is recorded; run `\(nextCommand(.surface))` first")
    }
    guard record.base != surface else { return }
    throw Refused(
      .gateBase,
      "run \(record.runID) measured its diff from "
        + (record.base ?? "no recorded base")
        + ", not the sprint's surface \(surface); run `swiftgate check --tier push --base "
        + "\(surface)` at HEAD and pass its id")
  }

  private static func requireGreenMain(_ base: String, _ context: SprintContext) throws(Refused) {
    let runs = RunStore(worktreeRoot: context.root)
    let records: [RunHistoryRecord]
    do {
      records = try runs.readHistory().records
    } catch {
      throw Refused(
        .historyUnreadable, "reading \(runs.historyFile.path): \(error); fix or move it and re-run")
    }
    let newest = records.last { record in
      guard record.headCommit == base,
        let tier = TaskReturnEvidence.GateRun.tier(ofCommand: record.command)
      else { return false }
      return TaskReturnCheck.covers(tier, .push)
    }
    guard let newest else {
      throw Refused(
        .mainNotGreen,
        "no push gate ran at \(mainBranch) (\(base)) in this checkout; run `swiftgate check "
          + "--tier push` on \(mainBranch) and re-run")
    }
    guard newest.verdict == .green else {
      throw Refused(
        .mainNotGreen,
        "the newest push gate at \(mainBranch) (\(base)), run \(newest.runID), is "
          + "\(newest.verdict.rawValue); fix \(mainBranch) first")
    }
  }

  /// A recorded proof base names the surface when it is its full sha or an abbreviation of it.
  /// Refs are not resolved: a branch name can have moved since the run.
  private static func names(_ recorded: String, _ surface: String) -> Bool {
    let lowered = recorded.lowercased()
    guard lowered.count >= 7, lowered.allSatisfy(\.isHexDigit) else { return false }
    return surface.hasPrefix(lowered)
  }

  private static func git<T>(_ what: String, _ body: () async throws(GitError) -> T)
    async throws(Refused) -> T
  {
    do {
      return try await body()
    } catch {
      throw Refused(.git, "git failed \(what): \(error)")
    }
  }

  private static func workspace<T>(
    _ what: String, _ body: () async throws(GitWorkspaceError) -> T
  ) async throws(Refused) -> T {
    do {
      return try await body()
    } catch {
      throw Refused(.git, "git failed \(what): \(error)")
    }
  }

  // MARK: - refusals

  private static func refusal(_ error: SprintTransitionError) -> Refused {
    switch error {
    case .outOfOrder(_, let expected):
      Refused(.outOfOrder, error.message + "; run `\(nextCommand(expected))` next")
    case .invalidSlug: Refused(.invalidSlug, error.message)
    case .invalidSpecPage: Refused(.invalidSpecPage, error.message)
    case .invalidCommit: Refused(.invalidCommit, error.message)
    case .invalidGateRun:
      Refused(.invalidGateRun, error.message + "; pass the id `swiftgate check` printed")
    case .invalidSliceCount: Refused(.invalidSliceCount, error.message)
    }
  }

  private static func refusal(_ error: SprintStoreError) -> Refused {
    switch error {
    case .transition(let transition):
      refusal(transition)
    case .commonDirectory(let detail):
      Refused(
        .commonDirectory, "can't find the git common dir: \(detail); run inside the repository")
    case .lock(let lock):
      Refused(
        .stateLocked,
        "another command holds the plan-state lock (\(lock)); re-run once it finishes")
    case .malformed(let path, let malformed):
      Refused(
        .stateMalformed,
        "\(path): \(malformed.message); restore it from the last good state, since removing it "
          + "forgets the sprint")
    case .io(let operation, let path, let reason):
      Refused(
        .stateIO, "\(operation) \(path) failed: \(reason); sprint.json is unchanged, re-run")
    case .stagingLeft(let operation, let path, let reason, let staging, let removal):
      Refused(
        .stateIO,
        "\(operation) \(path) failed: \(reason); sprint.json is unchanged, but its staging file "
          + "\(staging) couldn't be removed (\(removal)): delete it, then re-run")
    }
  }

  // MARK: - rendering

  static func nextCommand(_ step: SprintNextStep) -> String {
    switch step {
    case .start: "swiftgate sprint start <slug> --spec-page <path> --slices <n>"
    case .surface: "swiftgate sprint surface <surface sha>"
    case .slice(let n): "swiftgate sprint slice \(n) --gate <push run id>"
    case .finish: "swiftgate sprint finish --gate <ready run id>"
    }
  }

  private static func stepName(_ step: SprintStep) -> String {
    switch step {
    case .started: "started"
    case .surfaced: "surfaced"
    case .slicing: "slicing"
    case .finished: "finished"
    }
  }

  private static func describe(_ run: SprintRun) -> String {
    let passed = run.slices.filter { $0.status == .passed }.count
    return "\(stepName(run.step)), \(passed) of \(run.slices.count) slices passed"
  }

  private struct Report: Encodable {
    let command: String
    let verdict: Verdict
    let rule: String?
    let message: String
    let next: String
    let nextCommand: String
    let sprint: State?
  }

  private struct State: Encodable {
    let slug: String
    let specPage: String
    let branch: String
    let baseCommit: String
    let surfaceCommit: String?
    let step: String
    let slicesPassed: Int
    let slices: [Slice]
    let finalGateRun: String?
  }

  private struct Slice: Encodable {
    let number: Int
    let status: String
    let gateRun: String?
  }

  static func render(_ outcome: SprintOutcome, format: OutputFormat) -> String {
    let next = outcome.run?.next ?? .start
    switch format {
    case .json:
      let report = Report(
        command: outcome.command, verdict: outcome.verdict, rule: outcome.refusal?.rawValue,
        message: outcome.message, next: next.description, nextCommand: nextCommand(next),
        sprint: outcome.run.map { run in
          State(
            slug: run.slug, specPage: run.specPage, branch: run.branch,
            baseCommit: run.baseCommit, surfaceCommit: run.surfaceCommit,
            step: stepName(run.step),
            slicesPassed: run.slices.filter { $0.status == .passed }.count,
            slices: run.slices.map {
              Slice(number: $0.number, status: $0.status.rawValue, gateRun: $0.gateRun)
            },
            finalGateRun: run.finalGateRun)
        })
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      let data = (try? encoder.encode(report)) ?? Data()
      return String(decoding: data, as: UTF8.self)
    case .human:
      let head =
        outcome.refusal.map { "\(outcome.command): \($0.rawValue): \(outcome.message)" }
        ?? "\(outcome.command): \(outcome.message)"
      return head + "\nnext: \(next.description) (`\(nextCommand(next))`)"
    }
  }

  /// Wires the live adapters for the checkout at the working directory, prints, and exits 0
  /// GREEN, 1 on a refusal, 2 when state, history or git couldn't be read.
  static func execute(
    _ command: String, format: OutputFormat,
    _ body: (SprintContext) async -> SprintOutcome
  ) async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let runner = LiveProcessRunner()
    let git = LiveGit(runner: runner, repositoryRoot: root.path)
    let outcome: SprintOutcome
    do {
      let store = try await SprintStore.locate(git: git)
      outcome = await body(
        SprintContext(
          root: root, git: git,
          branches: LiveSprintBranches(runner: runner, repositoryRoot: root.path), store: store,
          surfaceReader: LiveSurfaceCommitReader(runner: runner, repositoryRoot: root.path)))
    } catch {
      let refused = refusal(error)
      outcome = SprintOutcome(
        command: command, refusal: refused.refusal, message: refused.message, run: nil)
    }
    Console.write(render(outcome, format: format))
    let status = outcome.verdict.exitCode
    if status != 0 { throw ExitCode(status) }
  }
}

struct SprintCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "sprint",
    abstract: "Run a sprint's steps in order: start, surface, slices, finish (fast modes §4).",
    discussion:
      "Each command checks its step, then records it in sprint.json in the git common dir. A "
      + "refusal exits 1 and names a sprint.<reason> rule id and what to do; exit 2 means the "
      + "sprint state, run history or git couldn't be read.",
    subcommands: [
      SprintStartCommand.self, SprintSurfaceCommand.self, SprintSliceCommand.self,
      SprintFinishCommand.self, SprintStatusCommand.self,
    ])
}

struct SprintStartCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "start", abstract: "Create sprint/<slug> from a green main and record the sprint.",
    discussion:
      "Needs a GREEN `check --tier push` (or above) run in this checkout's history at main's "
      + "HEAD. Creates the branch without switching to it.")

  @Argument(help: "Lowercase letters and digits joined by single hyphens.")
  var slug: String

  @Option(name: .customLong("spec-page"), help: "The sprint's 1-page spec.")
  var specPage: String

  @Option(help: "How many slices the spec page lists.")
  var slices: Int

  @OptionGroup var output: OutputOptions

  func run() async throws {
    try await SprintCommandRun.execute("sprint start", format: output.format) { context in
      await SprintCommandRun.start(
        slug: slug, specPage: specPage, slices: slices, context: context)
    }
  }
}

struct SprintSurfaceCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "surface", abstract: "Check the surface commit and record it.",
    discussion:
      "The surface is the first commit on sprint/<slug>. Runs surface-check on it and refuses "
      + "on any finding but its summary.")

  @Argument(help: "The surface commit.")
  var commit: String

  @OptionGroup var output: OutputOptions

  func run() async throws {
    try await SprintCommandRun.execute("sprint surface", format: output.format) { context in
      await SprintCommandRun.surface(commit: commit, context: context)
    }
  }
}

struct SprintSliceCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "slice", abstract: "Record a slice that passed its push gate at the branch HEAD.",
    discussion:
      "Reads the run from this checkout's run history: it must be a GREEN `check --tier push` or "
      + "`ready` run whose HEAD was the sprint branch's HEAD and whose `--base` was the sprint's "
      + "surface.")

  @Argument(help: "The slice's number on the spec page, from 1.")
  var number: Int

  @Option(help: "The push gate run's id, as `check` printed it.")
  var gate: String

  @OptionGroup var output: OutputOptions

  func run() async throws {
    try await SprintCommandRun.execute("sprint slice", format: output.format) { context in
      await SprintCommandRun.slice(number, gate: gate, context: context)
    }
  }
}

struct SprintFinishCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "finish", abstract: "Fast-forward main to a sprint whose ready gate is green.",
    discussion:
      "The run must be a GREEN `check --tier ready` at the branch HEAD that proved at the "
      + "sprint's surface (`--proof-base <surface>`), and main must still be where the sprint "
      + "started. Never merges or rebases.")

  @Option(help: "The ready gate run's id, as `check` printed it.")
  var gate: String

  @OptionGroup var output: OutputOptions

  func run() async throws {
    try await SprintCommandRun.execute("sprint finish", format: output.format) { context in
      await SprintCommandRun.finish(gate: gate, context: context)
    }
  }
}

struct SprintStatusCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "status", abstract: "Show the recorded sprint and the step it needs next.")

  @OptionGroup var output: OutputOptions

  func run() async throws {
    try await SprintCommandRun.execute("sprint status", format: output.format) { context in
      await SprintCommandRun.status(context: context)
    }
  }
}

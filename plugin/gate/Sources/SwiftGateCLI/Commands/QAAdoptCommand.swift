import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// What `qa adopt` did with a worktree's prepared checks.
struct QAAdoptReport: Sendable, Equatable, Encodable {
  /// 1 plan's `qa/` folder copied into plan state.
  struct Adopted: Sendable, Equatable, Encodable {
    var plan: String
    var files: Int
    var destination: String
  }

  /// A running task whose checked return waits to merge and that a validation row runs after:
  /// a merge of it that makes a row ready waits only on the adopted checks' `--at-base` run.
  struct Unblocked: Sendable, Equatable, Encodable {
    var plan: String
    var task: String
    /// The fixer's return is the one checked.
    var fix: Bool
    /// The exact command that merges it, once the `--at-base` run is done.
    var next: String
  }

  var worktree: String
  var verdict: Verdict = .blocked
  var adopted: [Adopted] = []
  /// The repair a `--repair` adopt took; `nil` otherwise, or when it took none.
  var repaired: QAFlowRepairRecord?
  /// In merge-queue order: merge the first while no merge is on `main` ungated.
  var unblocks: [Unblocked] = []
  /// Why a `--repair` adopt took nothing.
  var findings: [Finding] = []
  var message = ""

  private enum CodingKeys: String, CodingKey {
    case command, worktree, verdict, adopted, repaired, unblocks, findings, message
  }

  func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(QAAdoptRun.command, forKey: .command)
    try c.encode(worktree, forKey: .worktree)
    try c.encode(verdict, forKey: .verdict)
    try c.encode(adopted, forKey: .adopted)
    try c.encode(repaired, forKey: .repaired)
    try c.encode(unblocks, forKey: .unblocks)
    try c.encode(findings, forKey: .findings)
    try c.encode(message, forKey: .message)
  }
}

/// What `qa adopt --repair` takes: 1 requirement's rewritten checks, and why.
struct QAAdoptRepair: Sendable, Equatable {
  var requirement: String
  var buildRun: String
  var cause: QAFlowRepair.Cause
  var reason: String
  /// The `qa run`s that read the row red before the repair.
  var redRuns: [String]
}

/// `qa adopt`'s behaviour, apart from argument parsing so tests drive it against a temp repository.
enum QAAdoptRun {
  static let command = "qa adopt"
  /// Where a validation worker leaves its checks in its worktree, 1 folder per plan.
  static let preparedDirectory = RunLayout.treePath(RunLayout.qaPreparedDirectory)

  /// Copies nothing unless `worktree` is a checkout `git worktree list` names and every plan
  /// folder it holds names a plan that exists, so a refusal never leaves half an adoption.
  /// - Parameter session: the session holding the plan's lock, quoted in each `build merge` it
  ///   names; `<session>` when not given.
  static func run(
    worktree: String, root: URL, git: any Git, runner: any ProcessRunner, session: String? = nil
  ) async -> QAAdoptReport {
    var report = QAAdoptReport(worktree: worktree)
    func refused(_ message: String) -> QAAdoptReport {
      var refusal = report
      refusal.verdict = .red
      refusal.message = message + "; nothing was copied"
      return refusal
    }
    let target = CanonicalPath.of(URL(filePath: worktree, relativeTo: root))
    let checkouts: [String]
    do {
      checkouts = try await QACheckouts(runner: runner, repositoryRoot: root.path).paths()
    } catch {
      report.message = "listing this repository's checkouts: \(error)"
      return report
    }
    guard checkouts.contains(target) else {
      return refused(
        "\(target) is not a checkout of this repository: `git worktree list` names "
          + checkouts.joined(separator: ", "))
    }
    let layout: PlanStateLayout
    do {
      layout = try PlanStateLayout(commonDirectory: try await git.commonDirectory())
    } catch {
      report.message = "resolving the plan state directory: \(error)"
      return report
    }
    let prepared = URL(filePath: target, directoryHint: .isDirectory)
      .appending(path: preparedDirectory, directoryHint: .isDirectory)
    let names: [String]
    do {
      names = try QAFiles.subdirectories(of: prepared)
    } catch {
      report.message = "reading \(prepared.path): \(error)"
      return report
    }
    guard !names.isEmpty else {
      return refused("\(target) holds no \(preparedDirectory)/<plan>/ folder")
    }
    var plans: [(name: String, plan: PlanStateLayout.Plan)] = []
    for name in names {
      guard let plan = try? layout.plan(name),
        FileManager.default.fileExists(atPath: plan.directory)
      else {
        return refused("\(preparedDirectory)/\(name) names no plan under \(layout.root)")
      }
      plans.append((name, plan))
    }
    for (name, plan) in plans {
      let destination = URL(filePath: plan.directory, directoryHint: .isDirectory)
        .appending(path: QAReport.directory, directoryHint: .isDirectory)
      do {
        let files = try QAFiles.replace(
          destination, withCopyOf: prepared.appending(path: name, directoryHint: .isDirectory))
        report.adopted.append(
          QAAdoptReport.Adopted(plan: name, files: files, destination: destination.path))
      } catch {
        report.message =
          "copying \(preparedDirectory)/\(name): \(error)"
          + (report.adopted.isEmpty
            ? "" : "; already adopted: " + report.adopted.map(\.plan).joined(separator: ", "))
        return report
      }
    }
    report.verdict = .green
    report.message =
      "adopted "
      + report.adopted.map { "\($0.plan) (\($0.files) files)" }.joined(separator: ", ")
    for (name, plan) in plans {
      report.unblocks += await unblocked(
        plan: name, layout: plan, root: root, git: git, session: session)
    }
    if !report.unblocks.isEmpty {
      report.message +=
        "; once the --at-base run is done, \(report.unblocks.count) checked "
        + (report.unblocks.count == 1 ? "return waits" : "returns wait")
        + " to merge: run `build next` and merge the first in its readyToMerge"
    }
    return report
  }

  /// The running tasks of `plan`'s newest build run whose checked return waits to merge, in
  /// queue order, that a validation row runs after; none when the plan has no build run or its
  /// state doesn't read.
  static func unblocked(
    plan name: String, layout plan: PlanStateLayout.Plan, root: URL, git: any Git,
    session: String?
  ) async -> [QAAdoptReport.Unblocked] {
    guard
      let data = FileManager.default.contents(
        atPath: plan.directory + "/" + ValidationTable.fileName),
      let table = try? ValidationTableJSON.decode(data),
      let progress = try? PlanStateStore(plan: plan).ledgerProgress(),
      let store = try? await BuildRunStore.latest(plan: name, git: git),
      let log = try? store.events()
    else { return [] }
    let named = Set(table.rows.flatMap(\.runsAfter))
    let running = Set(progress.tasks.filter { $0.status == .inProgress }.map(\.id))
    let retried = BuildHalts.retried(
      in: (try? BuildHaltLog(root: root).events()) ?? [], buildRun: store.runID)
    return log.mergeQueue(running: running, retried: retried).ready
      .filter { named.contains($0.task) }
      .map { ready in
        QAAdoptReport.Unblocked(
          plan: name, task: ready.task, fix: ready.fix,
          next: "\"$SG\" build merge \(name) \(ready.task)\(ready.fix ? " --fix" : "") "
            + "--session \(session ?? "<session>") --json")
      }
  }

  /// Copies only `repair.requirement`'s checks from the worktree's prepared folder into plan
  /// state, merges their rows of the prepared `at-base-run.json` into plan state's, records the
  /// repair in `qa/repairs.json` and writes 1 `qa.repair` event, when ``QAFlowRepair`` finds
  /// nothing; otherwise copies nothing and names each finding.
  static func repair(
    _ repair: QAAdoptRepair, worktree: String, root: URL, git: any Git, runner: any ProcessRunner,
    events: (any HarnessEventWriting)?, now: @Sendable () -> Date,
    newEventID: @Sendable () -> String
  ) async -> QAAdoptReport {
    var report = QAAdoptReport(worktree: worktree)
    func refused(_ message: String) -> QAAdoptReport {
      var refusal = report
      refusal.verdict = .red
      refusal.message = message + "; nothing was copied"
      return refusal
    }
    let files = FileManager.default
    let target = CanonicalPath.of(URL(filePath: worktree, relativeTo: root))
    let checkouts: [String]
    do {
      checkouts = try await QACheckouts(runner: runner, repositoryRoot: root.path).paths()
    } catch {
      report.message = "listing this repository's checkouts: \(error)"
      return report
    }
    guard checkouts.contains(target) else {
      return refused(
        "\(target) is not a checkout of this repository: `git worktree list` names "
          + checkouts.joined(separator: ", "))
    }
    let layout: PlanStateLayout
    do {
      layout = try PlanStateLayout(commonDirectory: try await git.commonDirectory())
    } catch {
      report.message = "resolving the plan state directory: \(error)"
      return report
    }
    let preparedRoot = URL(filePath: target, directoryHint: .isDirectory)
      .appending(path: preparedDirectory, directoryHint: .isDirectory)
    let names: [String]
    do {
      names = try QAFiles.subdirectories(of: preparedRoot)
    } catch {
      report.message = "reading \(preparedRoot.path): \(error)"
      return report
    }
    guard names.count == 1, let name = names.first else {
      return refused(
        "a repair's \(preparedDirectory)/ holds 1 plan folder, and \(target) holds "
          + (names.isEmpty ? "none" : names.joined(separator: ", ")))
    }
    guard let plan = try? layout.plan(name), files.fileExists(atPath: plan.directory) else {
      return refused("\(preparedDirectory)/\(name) names no plan under \(layout.root)")
    }
    let prepared = preparedRoot.appending(path: name, directoryHint: .isDirectory)
    let qaFolder = URL(filePath: plan.directory, directoryHint: .isDirectory)
      .appending(path: QAReport.directory, directoryHint: .isDirectory)
    let tablePath = plan.directory + "/" + ValidationTable.fileName
    let table: ValidationTable
    do {
      guard let data = files.contents(atPath: tablePath) else {
        return refused("\(tablePath) is missing")
      }
      table = try ValidationTableJSON.decode(data)
    } catch {
      return refused("\(tablePath) doesn't read: \(error)")
    }
    let rows = table.rows.enumerated().compactMap { offset, row in
      row.requirement == repair.requirement && QAFlowRepair.preparedName(row.check) != nil
        ? (row: offset + 1, validation: row) : nil
    }
    guard !rows.isEmpty else {
      return refused(
        "no row of \(tablePath) checks `\(repair.requirement)` with a \(QAReport.directory)/ file")
    }
    var adopted: [String: Data] = [:]
    var repaired: [String: Data] = [:]
    for (_, row) in rows {
      guard let file = QAFlowRepair.preparedName(row.check) else { continue }
      adopted[row.check] = files.contents(atPath: qaFolder.appending(path: file).path)
      repaired[row.check] = files.contents(atPath: prepared.appending(path: file).path)
    }
    let preparedFiles = (try? files.contentsOfDirectory(atPath: prepared.path)) ?? []
    let adoptedRecordFile = qaFolder.appending(path: QAAtBaseRun.fileName)
    let adoptedRecord = files.contents(atPath: adoptedRecordFile.path).flatMap {
      try? QAAtBaseRunJSON.decode($0)
    }
    let preparedRecord = files.contents(
      atPath: prepared.appending(path: QAAtBaseRun.fileName).path
    ).flatMap { try? QAAtBaseRunJSON.decode($0) }
    let repairsFile = qaFolder.appending(path: QAFlowRepair.fileName)
    let earlier: [QAFlowRepairRecord]
    if let data = files.contents(atPath: repairsFile.path) {
      do {
        earlier = try QAFlowRepairs.decode(data).repairs
      } catch {
        return refused(
          "\(repairsFile.path) doesn't read, so the repair cap can't be read: \(error)")
      }
    } else {
      earlier = []
    }
    let worktrees = [URL(filePath: target, directoryHint: .isDirectory), root]
    let redRuns = repair.redRuns.map { runID in
      let found =
        QARunHistory.report(runID: runID, worktrees: worktrees)?.rows.filter {
          $0.requirement == repair.requirement
        } ?? []
      return QAFlowRepair.RedRun(
        runID: runID,
        row: found.first { $0.layer == .flow && $0.result == .red }
          ?? found.first { $0.result == .red } ?? found.first)
    }

    // A second repair needs the build run's box, read from its own record.
    let buildRecord = try? await BuildRunStore.open(plan: name, runID: repair.buildRun, git: git)
      .record()
    report.findings = QAFlowRepair.findings(
      QAFlowRepair.Input(
        requirement: repair.requirement, rows: rows, adopted: adopted, repaired: repaired,
        preparedFiles: preparedFiles, adoptedRecord: adoptedRecord,
        preparedRecord: preparedRecord, redRuns: redRuns, earlier: earlier,
        buildRun: repair.buildRun, now: now(), noNewStartsAt: buildRecord?.noNewStartsAt))
    guard report.findings.isEmpty, let preparedRecord else {
      return refused(
        "\(report.findings.count) finding(s) refuse the repair of \(repair.requirement)")
    }

    let flow = rows.first { $0.validation.layer == .flow }?.validation.check
    let changed = flow.flatMap { check -> (removed: [String], added: [String])? in
      guard let old = adopted[check], let new = repaired[check] else { return nil }
      return QAFlowRepair.changedCommands(adopted: old, repaired: new)
    }
    let failing = redRuns.compactMap(\.row).lazy.compactMap {
      QAFlowRepair.failingStep(in: $0.message)
    }.first
    let record = QAFlowRepairRecord(
      requirement: repair.requirement, rows: rows.map(\.row),
      checks: rows.map(\.validation.check), buildRun: repair.buildRun, cause: repair.cause,
      reason: repair.reason, redRuns: repair.redRuns, atBaseRun: preparedRecord.runID,
      failingStep: failing?.number, failingCommand: failing?.command,
      removed: changed?.removed ?? [], added: changed?.added ?? [])
    let merged =
      adoptedRecord?.replacing(requirement: repair.requirement, with: preparedRecord)
      ?? QAAtBaseRun(
        runID: preparedRecord.runID, preparedBy: preparedRecord.preparedBy,
        commit: preparedRecord.commit,
        rows: preparedRecord.rows.filter { $0.requirement == repair.requirement })
    var copied = 0
    do {
      for (_, row) in rows {
        guard let file = QAFlowRepair.preparedName(row.check),
          files.fileExists(atPath: prepared.appending(path: file).path)
        else { continue }
        try replaceFile(qaFolder.appending(path: file), with: prepared.appending(path: file))
        copied += 1
      }
      try QAFiles.write(try QAAtBaseRunJSON.encode(merged), to: adoptedRecordFile)
      try QAFiles.write(
        try QAFlowRepairs(repairs: earlier + [record]).encoded(), to: repairsFile)
    } catch {
      report.message =
        "copying the repair of \(repair.requirement) into \(qaFolder.path): \(error); "
        + "\(copied) check file(s) were already copied"
      return report
    }
    var notes: [String] = []
    if let events {
      do {
        try events.append(
          contentsOf: [
            HarnessEvent(
              eventID: newEventID(), time: now(), runID: preparedRecord.runID,
              source: HarnessEventSource(route: nil),
              payload: .qaRepair(QARepairEvent(plan: name, record: record)))
          ])
      } catch {
        notes.append("qa.repair event not written: \(error)")
      }
    } else {
      notes.append("qa.repair event not written: \(root.path) has no config that loads")
    }
    report.verdict = .green
    report.repaired = record
    report.adopted = [
      QAAdoptReport.Adopted(plan: name, files: copied, destination: qaFolder.path)
    ]
    var message =
      "repaired \(repair.requirement) in \(name): \(copied) check file(s), red at the base in "
      + "qa run \(preparedRecord.runID)"
    if !record.removed.isEmpty || !record.added.isEmpty {
      let removed = record.removed.map { "`\($0)`" }.joined(separator: ", ")
      let added = record.added.map { "`\($0)`" }.joined(separator: ", ")
      message += ", \(removed) replaced by \(added)"
    }
    for note in notes { message += "; \(note)" }
    report.message = message
    return report
  }

  /// Replaces `destination` with a copy of `source`, its permissions included, so a state script
  /// stays executable.
  private static func replaceFile(_ destination: URL, with source: URL) throws {
    let files = FileManager.default
    let staging = destination.deletingLastPathComponent().appending(
      path: ".\(destination.lastPathComponent).repairing")
    try? files.removeItem(at: staging)
    try files.copyItem(at: source, to: staging)
    if files.fileExists(atPath: destination.path) {
      _ = try files.replaceItemAt(destination, withItemAt: staging)
    } else {
      try files.moveItem(at: staging, to: destination)
    }
  }

  static func render(_ report: QAAdoptReport, json: Bool) -> String {
    guard json else {
      return
        (["\(command): \(report.verdict.rawValue) \(report.message)"]
        + report.findings.map { "  \($0.ruleID): \($0.message)" }
        + report.unblocks.map { "  \($0.task): \($0.next)" }).joined(separator: "\n")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return String(decoding: (try? encoder.encode(report)) ?? Data(), as: UTF8.self)
  }
}

/// `swiftgate qa adopt <worktree> [--repair <requirement> --build-run <run> --cause <cause>
/// --reason <text> --red-run <id>...] [--json]`.
struct QAAdoptCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "adopt",
    abstract:
      "Copy a validation worktree's .harness/qa/<plan>/ into that plan's state as qa/, or 1 "
      + "requirement's repaired checks with --repair.")

  @Argument(help: "A checkout of this repository holding .harness/qa/<plan>/.")
  var worktree: String

  @Option(
    help: ArgumentHelp(
      "Take only this requirement's rewritten checks, proved red at the base by the worktree's "
        + "--prepared-by --requirement run, in place of the adopted ones."))
  var repair: String?

  @Option(help: "With --repair, the build run the repair counts against: 1 per requirement.")
  var buildRun: String?

  @Option(help: "With --repair, flow-side or still-red.")
  var cause: QAFlowRepair.Cause?

  @Option(help: "With --repair, why the flow, not the app, kept the row red.")
  var reason: String?

  @Option(help: "With --repair, a qa run that read the row red before the repair; repeat it.")
  var redRun: [String] = []

  @Option(help: "The session id holding the plan's lock, quoted in the build merge it names.")
  var session: String?

  @Flag(help: "Print JSON.")
  var json = false

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let runner = LiveProcessRunner()
    let git = LiveGit(runner: runner, repositoryRoot: root.path)
    let report: QAAdoptReport
    if let requirement = repair {
      guard let buildRun, let cause, let reason else {
        throw ValidationError("--repair needs --build-run, --cause and --reason")
      }
      report = await QAAdoptRun.repair(
        QAAdoptRepair(
          requirement: requirement, buildRun: buildRun, cause: cause, reason: reason,
          redRuns: redRun),
        worktree: worktree, root: root, git: git, runner: runner,
        events: TelemetryOptIn.writer(root: root),
        now: { Date() },  // swiftgate:allow det.date-init — the CLI edge stamps the repair
        newEventID: {
          UUID().uuidString  // swiftgate:allow det.uuid-init — an event id need only be unique
        })
    } else {
      report = await QAAdoptRun.run(
        worktree: worktree, root: root, git: git, runner: runner, session: session)
    }
    Console.write(QAAdoptRun.render(report, json: json))
    if report.verdict != .green { throw ExitCode(report.verdict.exitCode) }
  }
}
extension QAFlowRepair.Cause: ExpressibleByArgument {}

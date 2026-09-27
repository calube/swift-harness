import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// What `ledger set` did to one task in a plan's `ledger.json`.
struct LedgerSetReport: Sendable, Equatable, Encodable {
  enum Status: String, Sendable, Encodable {
    case updated
    /// The lock is free or another session holds it; nothing was written.
    case notHeld = "not-held"
    case blocked
  }

  let command: String
  let plan: String
  let task: String
  let status: Status
  let verdict: Verdict
  /// The session holding the lock when it isn't the caller.
  let holder: String?
  let from: TaskStatus?
  let to: TaskStatus?
  /// The build run the transition event was appended to.
  let runID: String?
  let message: String

  private enum CodingKeys: String, CodingKey {
    case command, plan, task, status, verdict, holder, from, to, message
    case runID = "runId"
  }
}

/// The testable core of `ledger set` (spec §6.2): the lock holder's one legal status change,
/// recorded in `ledger.json` and as one transition event in the plan's newest build run.
enum LedgerSetRun {
  static let noBuildRun = "no build run: run `swiftgate build start` first"

  static func run(
    plan: String, task: String, status: String, session: String?, now: Date, git: any Git
  ) async -> LedgerSetReport {
    let blocked = { (message: String) in
      LedgerSetReport(
        command: "ledger set", plan: plan, task: task, status: .blocked, verdict: .blocked,
        holder: nil, from: nil, to: nil, runID: nil, message: message)
    }
    guard let target = TaskStatus(rawValue: status) else {
      let allowed = TaskStatus.allCases.map(\.rawValue).joined(separator: ", ")
      return blocked("status `\(status)` must be one of \(allowed)")
    }
    guard let session else {
      return blocked("--session is required: pass the id from the SessionStart context")
    }
    guard PlanLock.isValidSession(session) else {
      return blocked("--session must be a non-empty id without whitespace")
    }
    let store: PlanStateStore
    do throws(PlanStateStoreError) {
      store = try await PlanStateStore.locate(slug: plan, git: git)
    } catch {
      return blocked("can't locate plan `\(plan)`: \(error)")
    }
    let lock = PlanLock(plan: store.plan)
    let holder: String?
    do {
      holder = try lock.holder()
    } catch {
      return blocked("can't read \(lock.plan.orchestratorLock): \(error)")
    }
    guard let holder, holder == session else {
      return LedgerSetReport(
        command: "ledger set", plan: plan, task: task, status: .notHeld, verdict: .red,
        holder: holder, from: nil, to: nil, runID: nil,
        message: holder.map { PlanLockRun.heldByOtherMessage(plan, $0) }
          ?? "plan `\(plan)` isn't claimed; only the session holding its lock changes its ledger.")
    }
    let ledger: Ledger
    do throws(PlanStateStoreError) {
      ledger = try store.ledger()
    } catch {
      return blocked("\(error); the ledger was left as it is")
    }
    guard let index = ledger.tasks.firstIndex(where: { $0.id == task }) else {
      return blocked("plan `\(plan)` has no task `\(task)`")
    }
    let current = ledger.tasks[index]
    if case .refused(let reason) = LedgerTransition.check(from: current.status, to: target) {
      return blocked("task `\(task)`: \(reason)")
    }
    let run: BuildRunStore
    do {
      guard let runID = try latestRunID(in: store.plan.buildDirectory) else {
        return blocked(noBuildRun)
      }
      run = try await BuildRunStore.open(plan: plan, runID: runID, git: git)
    } catch {
      return blocked("can't find plan `\(plan)`'s build run: \(error)")
    }
    var tasks = ledger.tasks
    tasks[index] = LedgerTask(
      id: current.id, deps: current.deps, writeSet: current.writeSet, gate: current.gate,
      tests: current.tests, covers: current.covers, estLines: current.estLines, status: target,
      worktree: current.worktree, actualLines: current.actualLines, model: current.model,
      branch: current.branch)
    let updated = Ledger(
      schemaVersion: ledger.schemaVersion, resume: ledger.resume, maxParallel: ledger.maxParallel,
      tasks: tasks, waves: ledger.waves)
    let path = store.plan.ledgerFile
    do {
      // Renamed over the old file: a reader sees one whole ledger or the other.
      try LedgerJSON.encode(updated).write(to: URL(filePath: path), options: .atomic)
    } catch {
      return blocked("writing \(path): \(error)")
    }
    do throws(BuildRunStoreError) {
      try await run.append(
        .transition(.init(task: task, from: current.status, to: target, at: now)))
    } catch {
      return blocked(
        "task `\(task)` is now \(target.rawValue) in the ledger, but its event wasn't recorded in "
          + "run \(run.runID): \(error)")
    }
    return LedgerSetReport(
      command: "ledger set", plan: plan, task: task, status: .updated, verdict: .green,
      holder: nil, from: current.status, to: target, runID: run.runID,
      message: "task `\(task)`: \(current.status.rawValue) -> \(target.rawValue) (run \(run.runID))"
    )
  }

  /// The newest run under `build/`: run ids start with their UTC start time, so the greatest
  /// sorts last. `nil` when no run has started.
  static func latestRunID(in buildDirectory: String) throws -> String? {
    let names: [String]
    do {
      names = try FileManager.default.contentsOfDirectory(atPath: buildDirectory)
    } catch CocoaError.fileReadNoSuchFile {
      return nil
    }
    return names.filter { name in
      var isDirectory: ObjCBool = false
      return RunID.isValid(name)
        && FileManager.default.fileExists(
          atPath: buildDirectory + "/" + name, isDirectory: &isDirectory)
        && isDirectory.boolValue
    }.max()
  }

  static func render(_ report: LedgerSetReport, format: OutputFormat) -> String {
    switch format {
    case .json:
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      let data = (try? encoder.encode(report)) ?? Data()
      return String(decoding: data, as: UTF8.self)
    case .human:
      return "\(report.command): \(report.verdict.rawValue) \(report.message)"
    }
  }
}

struct LedgerSetCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "set",
    abstract:
      "Change one task's status, rejecting a transition its current status can't legally make.",
    discussion:
      "Rewrites ledger.json whole and appends one transition event to the plan's newest build "
      + "run. Exits 0 when updated, 1 when this session doesn't hold the plan's lock, and 2 for "
      + "an illegal transition, an unknown task or status, a missing or invalid --session, no "
      + "build run, or unreadable plan state.")

  @Argument(help: "The plan's slug.")
  var plan: String

  @Argument(help: "The task's id.")
  var task: String

  @Argument(help: "The task's new status.")
  var status: String

  @Option(help: "The session id holding the plan's lock (from the SessionStart context).")
  var session: String?

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let git = LiveGit(runner: LiveProcessRunner(), repositoryRoot: root.path)
    let report = await LedgerSetRun.run(
      plan: plan, task: task, status: status, session: session, now: Date(), git: git)
    Console.write(LedgerSetRun.render(report, format: output.format))
    if report.verdict != .green { throw ExitCode(report.verdict.exitCode) }
  }
}

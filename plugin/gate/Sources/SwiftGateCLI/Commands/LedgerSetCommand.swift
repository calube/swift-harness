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
    do throws(BuildRunStoreError) {
      guard let latest = try await BuildRunStore.latest(plan: plan, git: git) else {
        return blocked(noBuildRun)
      }
      run = latest
    } catch {
      return blocked("can't find plan `\(plan)`'s build run: \(error)")
    }
    let change: LedgerWriter.Change
    do throws(LedgerWriterError) {
      change = try await LedgerWriter(plan: store.plan).update(task: task, .status(target))
    } catch {
      return blocked(message(for: error, plan: plan, task: task, path: store.plan.ledgerFile))
    }
    let from = change.before.status
    do throws(BuildRunStoreError) {
      try await run.append(.transition(.init(task: task, from: from, to: target, at: now)))
    } catch {
      return blocked(
        "task `\(task)` is now \(target.rawValue) in the ledger, but its event wasn't recorded in "
          + "run \(run.runID): \(error)")
    }
    return LedgerSetReport(
      command: "ledger set", plan: plan, task: task, status: .updated, verdict: .green,
      holder: nil, from: from, to: target, runID: run.runID,
      message: "task `\(task)`: \(from.rawValue) -> \(target.rawValue) (run \(run.runID))"
    )
  }

  /// The same wording as the checks made before the lock, for a ledger that changed under it.
  private static func message(
    for error: LedgerWriterError, plan: String, task: String, path: String
  ) -> String {
    switch error {
    case .ledger(let read): "\(read); the ledger was left as it is"
    case .unknownTask: "plan `\(plan)` has no task `\(task)`"
    case .refusedTransition(_, let reason): "task `\(task)`: \(reason)"
    case .lock, .io: "writing \(path): \(error)"
    }
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

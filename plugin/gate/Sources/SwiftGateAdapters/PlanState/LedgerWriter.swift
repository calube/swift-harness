import Foundation
import SwiftGateDomain

/// One change to one task's entry in `ledger.json`.
public enum LedgerEdit: Sendable, Equatable {
  /// Moves the task to a new status, refused unless ``LedgerTransition`` allows it from the
  /// status read under the lock.
  case status(TaskStatus)
  /// Records the task's worktree branch.
  case branch(String)
}

/// Every case means `ledger.json` was left exactly as it was.
public enum LedgerWriterError: Error, Sendable, Equatable {
  case lock(FileLockError)
  case ledger(PlanStateStoreError)
  case unknownTask(String)
  case refusedTransition(task: String, reason: String)
  case io(operation: String, path: String, reason: String)

  public var verdict: Verdict { .blocked }
}

/// Read-modify-write of one plan's `ledger.json` under a one-slot ``FileCountingLock`` in the
/// plan's directory, so two commands changing different tasks, in any process or worktree, never
/// write back a ledger read before the other's change landed.
public struct LedgerWriter: Sendable {
  /// A task's entry as read under the lock and as written.
  public struct Change: Sendable, Equatable {
    public let before: LedgerTask
    public let after: LedgerTask
  }

  public let plan: PlanStateLayout.Plan
  private let lock: any CountingLock
  private let timeout: Duration

  public init(
    plan: PlanStateLayout.Plan, lock: (any CountingLock)? = nil, timeout: Duration = .seconds(30)
  ) {
    self.plan = plan
    self.lock =
      lock
      ?? FileCountingLock(
        directory: URL(filePath: plan.directory, directoryHint: .isDirectory),
        name: "ledger.lock", capacity: 1, pollInterval: .milliseconds(5))
    self.timeout = timeout
  }

  /// Applies `edit` to `task` in the ledger as it is once the lock is held, and replaces the file
  /// whole: a reader sees one whole ledger or the other.
  @discardableResult
  public func update(task: String, _ edit: LedgerEdit) async throws(LedgerWriterError) -> Change {
    let lease: LockLease
    do {
      lease = try await lock.acquire(timeout: timeout)
    } catch {
      throw .lock(error)
    }
    defer { lease.release() }

    let ledger: Ledger
    do throws(PlanStateStoreError) {
      ledger = try PlanStateStore(plan: plan).ledger()
    } catch {
      throw .ledger(error)
    }
    guard let index = ledger.tasks.firstIndex(where: { $0.id == task }) else {
      throw .unknownTask(task)
    }
    let before = ledger.tasks[index]
    let after = try Self.apply(edit, to: before)
    var tasks = ledger.tasks
    tasks[index] = after
    let updated = Ledger(
      schemaVersion: ledger.schemaVersion, resume: ledger.resume, maxParallel: ledger.maxParallel,
      tasks: tasks, waves: ledger.waves)
    let data: Data
    do {
      data = try LedgerJSON.encode(updated)
    } catch {
      throw .io(operation: "encode", path: plan.ledgerFile, reason: String(describing: error))
    }
    do {
      try data.write(to: URL(filePath: plan.ledgerFile), options: .atomic)
    } catch {
      throw .io(operation: "write", path: plan.ledgerFile, reason: error.localizedDescription)
    }
    return Change(before: before, after: after)
  }

  private static func apply(_ edit: LedgerEdit, to task: LedgerTask)
    throws(LedgerWriterError) -> LedgerTask
  {
    var status = task.status
    var branch = task.branch
    switch edit {
    case .status(let target):
      if case .refused(let reason) = LedgerTransition.check(from: task.status, to: target) {
        throw .refusedTransition(task: task.id, reason: reason)
      }
      status = target
    case .branch(let name):
      branch = name
    }
    return LedgerTask(
      id: task.id, deps: task.deps, writeSet: task.writeSet, gate: task.gate, tests: task.tests,
      covers: task.covers, estLines: task.estLines, status: status, worktree: task.worktree,
      actualLines: task.actualLines, model: task.model, branch: branch)
  }
}

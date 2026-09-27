import Foundation
import SwiftGateDomain
import Testing

/// A worker pack's dependency-notes section (spec §5.3): the notes of every task the worker's task
/// depends on, verbatim, in the ledger's dependency order.
@Suite("Worker pack dependency notes (spec §5.3)")
struct WorkerPackDependencyNotesTests {
  private static func task(_ id: String, deps: [String] = []) -> LedgerTask {
    LedgerTask(
      id: id, deps: deps, writeSet: ["Packages/\(id)/"], gate: .fast, tests: [], covers: [],
      estLines: 10, status: .pending, worktree: "../myapp-plan-\(id)")
  }

  /// `waves` lists tasks in the order the ledger schedules them — later than every task they
  /// depend on. Building it by hand (rather than through `PlanSchedule`) keeps this suite focused
  /// on `dependencyOrder`/`workerPack`, not the scheduler.
  private static let ledger = Ledger(
    schemaVersion: 1, resume: "", maxParallel: 3,
    tasks: [task("dep-a"), task("dep-b"), task("main-task", deps: ["dep-a", "dep-b"])],
    waves: [["dep-b"], ["dep-a"], ["main-task"]])

  private func workerInputs(dependencyNotes: [DependencyReturnNotes]) -> WorkerInputs {
    let designSource = ContextSource(
      label: "design.md",
      rawText: "# Design\n\n## Decision\n\nPersist it.\n\n## Architecture\n\nOne file.\n")
    return WorkerInputs(
      task: Self.task("main-task", deps: ["dep-a", "dep-b"]),
      design: DesignDocument(markdown: .parse(designSource.rawText)), designSource: designSource,
      claims: ContextSource(label: "claims.jsonl", rawText: ""), citedClaimIDs: [],
      standards: ContextSource(label: "standards", rawText: ""), moduleKindAnchors: [],
      dependencyNotes: dependencyNotes)
  }

  // MARK: - Dependency order

  @Test(
    "dependency order follows the ledger's waves, not the order a task lists its deps — catches a pack that lists dependency notes out of schedule order"
  )
  func dependencyOrderFollowsLedgerWaves() {
    // `main-task` lists `dep-a` before `dep-b`, but the ledger schedules `dep-b` first.
    #expect(
      ContextPack.dependencyOrder(of: ["dep-a", "dep-b"], in: Self.ledger) == [
        "dep-b", "dep-a",
      ])
  }

  @Test(
    "a dependency absent from the ledger's waves sorts after every scheduled one, then by id — catches a crash or arbitrary order on a stale ledger"
  )
  func dependencyOrderFallsBackToIDForUnscheduledDeps() {
    #expect(
      ContextPack.dependencyOrder(of: ["unscheduled-z", "dep-a", "unscheduled-a"], in: Self.ledger)
        == [
          "dep-a", "unscheduled-a", "unscheduled-z",
        ])
  }

  // MARK: - Worker pack section

  @Test(
    "a worker pack with two dependencies carries both notes verbatim, headed by their ids, in dependency order — catches a pack that drops or reorders a dependency's notes"
  )
  func workerPackCarriesBothDependencyNotesInOrder() throws {
    let pack = try ContextPack.build(
      role: .worker,
      inputs: .worker(
        workerInputs(dependencyNotes: [
          DependencyReturnNotes(taskID: "dep-b", notes: "dep-b returns [Product]; page size 20"),
          DependencyReturnNotes(taskID: "dep-a", notes: "dep-a exposes fetchNext(after:)"),
        ])))

    let section = try #require(
      pack.slices.first { $0.sourceLabel == "Notes from the tasks this one depends on" })
    #expect(
      section.lines == [
        "dep-b", "dep-b returns [Product]; page size 20",
        "dep-a", "dep-a exposes fetchNext(after:)",
      ])
  }

  @Test(
    "a dependency with no task return fails loudly, never a thin pack — catches a pack that silently omits a missing dependency's notes"
  )
  func workerPackFailsLoudlyOnMissingDependencyReturn() {
    #expect(throws: ContextPackError.missingDependencyReturn(task: "dep-b")) {
      try ContextPack.build(
        role: .worker,
        inputs: .worker(
          workerInputs(dependencyNotes: [
            DependencyReturnNotes(taskID: "dep-a", notes: "dep-a exposes fetchNext(after:)"),
            DependencyReturnNotes(taskID: "dep-b", notes: nil),
          ])))
    }
  }

  @Test(
    "a worker pack with no dependency notes carries no dependency-notes section — catches a section appearing when the task has no deps or no --build-run was given"
  )
  func workerPackOmitsSectionWhenNoDependencyNotes() throws {
    let pack = try ContextPack.build(
      role: .worker, inputs: .worker(workerInputs(dependencyNotes: [])))

    #expect(!pack.slices.contains { $0.sourceLabel == "Notes from the tasks this one depends on" })
  }
}

import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// What `build cutoff` decided for a brownfield run's not-done tasks.
struct BuildCutoffReport: Sendable, Equatable, Encodable {
  let command: String
  let plan: String
  let runId: String
  let at: Date
  let endsAt: Date
  /// Tasks whose merge gate still fits: merge them, in this order, then run `final`.
  let finish: [String]
  /// The tasks in `finish` whose merge and GREEN merge gate are already recorded: only the steps
  /// after a merge gate are left for them.
  let landed: [String]
  /// Tasks set `abandoned`, each with why it didn't fit the box.
  let abandoned: [CutoffDecision]
  /// Tasks that never started and stay as they are.
  let notStarted: [String]
  /// Where the decisions were written for the report.
  let path: String
  /// Telemetry lines that failed; the decisions stand without them.
  let notes: [String]
}

/// `build cutoff`: the brownfield run's answer to the time box's cutoff, decided by
/// ``CutoffRule`` with no one asked.
enum BuildCutoffRun {
  static let command = "build cutoff"

  /// Acts at the cutoff, or once starts have stopped with nothing running, when the only tasks
  /// left are ones that never started. Owned runs, which have no box, are refused: their build
  /// halts and asks.
  static func run(
    slug: String, session: String?, git: any Git, clock: any BuildClock,
    telemetry: BuildCutoffTelemetry?
  ) async -> BuildLoopResult<BuildCutoffReport> {
    if let refusal: BuildLoopResult<BuildCutoffReport> = await BuildLoop.authorize(
      command, slug: slug, session: session, git: git)
    {
      return refusal
    }
    do throws(BuildLoopError) {
      let plan: PlanStateLayout.Plan
      do {
        plan = try await BuildLoop.planLayout(slug, git: git).plan(slug)
      } catch {
        return .blocked(command, slug, "invalid plan name `\(slug)`: \(error)")
      }
      let store: BuildRunStore
      let record: BuildRunRecord
      let log: BuildEventLog
      do throws(BuildRunStoreError) {
        guard let latest = try await BuildRunStore.latest(plan: slug, git: git) else {
          return .blocked(command, slug, "plan `\(slug)` has no build run to cut off")
        }
        store = latest
        record = try store.record()
        log = try store.events()
      } catch {
        return .blocked(command, slug, "reading plan `\(slug)`'s build run: \(error)")
      }
      guard let box = record.timeBox else {
        return .blocked(
          command, slug,
          "build run \(record.runID) has no time box: an owned build halts and asks at its "
            + "cutoff, and only a `swiftgate run` decides its own")
      }
      let ledger = try BuildLoop.ledger(plan)
      let now = clock.now()
      let running = ledger.tasks.filter { $0.status == .inProgress }
      let phase = box.phase(at: now)
      guard phase == .cutoff || (phase == .noNewStarts && running.isEmpty) else {
        let wait = max(0, Int(box.deadlines.cutoffAt.timeIntervalSince(now).rounded(.up)))
        return .refused(
          command, slug, .red,
          "the cutoff comes in \(wait) s, at \(box.deadlines.cutoffAt.formatted(.iso8601)); "
            + "running tasks keep going until then")
      }
      let merged = Set(log.mergedTasks)
      let tasks = ledger.tasks.compactMap { task -> CutoffTask? in
        switch task.status {
        case .inProgress:
          let gating =
            merged.contains(task.id)
            || readyToMerge(task.id, run: store.layout.directory)
          return CutoffTask(id: task.id, stage: gating ? .gating : .working)
        case .pending, .blocked: return CutoffTask(id: task.id, stage: .notStarted)
        case .done, .abandoned, .needsReplan: return nil
        }
      }
      let decisions = CutoffRule.decide(tasks: tasks, timeBox: box, now: now)
      let path = store.layout.directory + "/" + CutoffRecord.fileName
      do {
        try CutoffRecord(at: now, timeBox: box, decisions: decisions).encoded()
          .write(to: URL(filePath: path), options: .atomic)
      } catch {
        return .blocked(command, slug, "writing \(path): \(error)")
      }
      let abandoned = decisions.filter { $0.action == .abandon }
      for decision in abandoned {
        let set = await LedgerSetRun.run(
          plan: slug, task: decision.task, status: TaskStatus.abandoned.rawValue,
          session: session, now: now, git: git)
        guard set.verdict == .green else {
          return .blocked(
            command, slug,
            "abandoning `\(decision.task)`: \(set.message); the decisions are in \(path)")
        }
      }
      let notes = recordHalts(decisions, run: record.runID, telemetry: telemetry)
      return BuildLoopResult(
        command: command, plan: slug, verdict: .green,
        report: BuildCutoffReport(
          command: command, plan: slug, runId: record.runID, at: now,
          endsAt: box.deadlines.endsAt,
          finish: decisions.filter { $0.action == .finishMerge }.map(\.task),
          landed: [],
          abandoned: abandoned,
          notStarted: decisions.filter { $0.action == .notStarted }.map(\.task), path: path,
          notes: notes),
        holder: nil,
        message: "cut off build run \(record.runID): \(abandoned.count) task(s) abandoned")
    } catch {
      return .blocked(command, slug, error.message)
    }
  }

  /// Whether the run holds a checked `ready-to-merge` return for `task`.
  private static func readyToMerge(_ task: String, run directory: String) -> Bool {
    guard
      let data = try? Data(contentsOf: URL(filePath: directory + "/returns/\(task).json")),
      let taskReturn = try? TaskReturnJSON.decode(data)
    else { return false }
    return taskReturn.outcome == .readyToMerge
  }

  /// The cutoff as answered halts: 1 for the run, then 1 per running task, each resumed at once
  /// with what the rule chose, so the viewer and the halt summary show it and none stays open.
  /// Returns a line per event that failed; the decisions stand without them.
  private static func recordHalts(
    _ decisions: [CutoffDecision], run: String, telemetry: BuildCutoffTelemetry?
  ) -> [String] {
    guard let telemetry, telemetry.enabled else { return [] }
    var notes: [String] = []
    func pair(_ task: String?, _ answer: BuildResumeAnswer) {
      do throws(BuildHaltLogError) {
        _ = try telemetry.log.halt(buildRun: run, task: task, reason: .budget)
        _ = try telemetry.log.resume(buildRun: run, task: task, answer: answer)
      } catch {
        notes.append("the cutoff's halt for \(task ?? "the run") wasn't recorded: \(error)")
      }
    }
    pair(nil, .continue)
    for decision in decisions {
      switch decision.action {
      case .finishMerge: pair(decision.task, .continue)
      case .abandon: pair(decision.task, .abandon)
      case .notStarted: continue
      }
    }
    return notes
  }

  static func render(_ result: BuildLoopResult<BuildCutoffReport>, format: OutputFormat) -> String {
    BuildLoop.render(result, format: format) { report in
      func list(_ ids: [String]) -> String { ids.isEmpty ? "none" : ids.joined(separator: ", ") }
      return "build cutoff: run \(report.runId); finish: \(list(report.finish)); abandoned: "
        + list(report.abandoned.map { "\($0.task) (\($0.reason))" })
        + "; never started: \(list(report.notStarted))"
    }
  }
}

/// Where `build cutoff` records its halts, and whether the repository keeps events.
struct BuildCutoffTelemetry {
  let log: BuildHaltLog
  let enabled: Bool
}

struct BuildCutoffCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "cutoff",
    abstract: "Decide a brownfield run's in-flight tasks at its time box's cutoff, asking no one.",
    discussion:
      "Brownfield runs only: an owned build halts and asks at its cutoff. Lets each task "
      + "already gating finish its merge while that merge, `final` and the report still fit "
      + "in the box, sets every other running task `abandoned` with the reason, and writes "
      + "the decisions to the run's cutoff.json. It also acts once starts have stopped with "
      + "nothing running, naming the tasks that never started. Exits 0 when it decided, 1 "
      + "when --session doesn't hold the plan's lock or the cutoff hasn't come, and 2 for an "
      + "owned run, a missing --session or unreadable plan state.")

  @Argument(help: "The plan's slug.")
  var plan: String

  @Option(help: "The session id holding the plan's lock (from the SessionStart context).")
  var session: String?

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let telemetry: BuildCutoffTelemetry?
    switch await BuildHaltRun.store(command: BuildCutoffRun.command) {
    case .found(let root, let enabled):
      telemetry = BuildCutoffTelemetry(log: BuildHaltLog(root: root), enabled: enabled)
    case .refused(let output):
      // The cutoff still decides; only its halts go unrecorded, and the report says so.
      FileHandle.standardError.write(Data(output.stderr.utf8))
      telemetry = nil
    }
    let result = await BuildCutoffRun.run(
      slug: plan, session: session, git: BuildLoop.git(), clock: LiveBuildClock(),
      telemetry: telemetry)
    Console.write(BuildCutoffRun.render(result, format: output.format))
    try BuildLoop.exit(result)
  }
}

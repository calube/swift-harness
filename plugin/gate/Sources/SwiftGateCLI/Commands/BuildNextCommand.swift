import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

struct BuildNextReport: Sendable, Equatable, Encodable {
  struct Refused: Sendable, Equatable, Encodable {
    let task: String
    let reason: String
  }

  let runId: String
  let phase: BudgetPhase
  let toStart: [String]
  let running: [String]
  let refused: [Refused]
}

enum BuildNextRun {
  static func run(slug: String, session: String?, git: any Git, clock: any BuildClock) async
    -> BuildLoopResult<BuildNextReport>
  {
    let command = "build next"
    if let refusal: BuildLoopResult<BuildNextReport> = await BuildLoop.authorize(
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
      guard let runID = try latestRunID(plan) else {
        return .blocked(
          command, slug,
          "plan `\(slug)` has no build run under \(plan.buildDirectory); run "
            + "`swiftgate build start \(slug) --preset <name> --session <id>` first")
      }
      let record: BuildRunRecord
      do {
        record = try await BuildRunStore.open(plan: slug, runID: runID, git: git).record()
      } catch {
        return .blocked(command, slug, "reading build run \(runID): \(error)")
      }
      let ledger = try BuildLoop.ledger(plan)
      let running = Set(ledger.tasks.filter { $0.status == .inProgress }.map(\.id))
      let result = BuildScheduler.next(
        ledger: ledger, running: running, preset: record.preset, startedAt: record.startedAt,
        now: clock.now())
      let report = BuildNextReport(
        runId: runID, phase: result.phase, toStart: result.toStart, running: result.running,
        refused: result.refused.map {
          BuildNextReport.Refused(task: $0.taskID, reason: Self.reason($0.reason))
        })
      return BuildLoopResult(
        command: command, plan: slug, verdict: .green, report: report, holder: nil,
        message: "phase \(result.phase.rawValue)")
    } catch {
      return .blocked(command, slug, error.message)
    }
  }

  /// Run ids start with their UTC start time at a fixed width, so the newest sorts last.
  private static func latestRunID(_ plan: PlanStateLayout.Plan) throws(BuildLoopError)
    -> String?
  {
    let names: [String]
    do {
      names = try FileManager.default.contentsOfDirectory(atPath: plan.buildDirectory)
    } catch CocoaError.fileReadNoSuchFile {
      return nil
    } catch {
      throw BuildLoopError("listing \(plan.buildDirectory): \(error)")
    }
    return names.filter { (try? plan.buildRun($0)) != nil }.max()
  }

  private static func reason(_ reason: BuildScheduler.RefusalReason) -> String {
    switch reason {
    case .missingModel: "missing-model"
    }
  }

  static func render(_ result: BuildLoopResult<BuildNextReport>, format: OutputFormat) -> String {
    BuildLoop.render(result, format: format) { report in
      func list(_ ids: [String]) -> String { ids.isEmpty ? "none" : ids.joined(separator: ", ") }
      var line =
        "build next: run \(report.runId), phase \(report.phase.rawValue); start: "
        + "\(list(report.toStart)); running: \(list(report.running))"
      if !report.refused.isEmpty {
        line +=
          "; refused: "
          + report.refused.map { "\($0.task) (\($0.reason))" }.joined(separator: ", ")
      }
      return line
    }
  }
}

struct BuildNextCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "next",
    abstract: "Report the tasks to start now, the running tasks, and the time-budget phase.",
    discussion:
      "Reads the plan's newest build run and its ledger; writes nothing. Exits 0 with the "
      + "report, 1 when --session doesn't hold the plan's lock, and 2 for a missing --session, "
      + "no build run, or unreadable plan state.")

  @Argument(help: "The plan's slug.")
  var plan: String

  @Option(help: "The session id holding the plan's lock (from the SessionStart context).")
  var session: String?

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let result = await BuildNextRun.run(
      slug: plan, session: session, git: BuildLoop.git(), clock: LiveBuildClock())
    Console.write(BuildNextRun.render(result, format: output.format))
    try BuildLoop.exit(result)
  }
}

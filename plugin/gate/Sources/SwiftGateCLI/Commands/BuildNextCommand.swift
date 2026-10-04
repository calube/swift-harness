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
  /// Every not-done task the app target needs, which the no-new-starts phase still starts.
  let required: [Required]
  /// Minutes the stall watch lets a worker's transcripts sit unchanged: the preset's `stall_min`,
  /// or `nil` when the preset doesn't say.
  let stallMin: Int?
  /// A `swiftgate run`'s box: when starts stop, when the cutoff comes and when the box ends.
  /// Absent for a run without one.
  let timeBox: TimeBox?

  struct TimeBox: Sendable, Equatable, Encodable {
    let noNewStartsAt: Date
    let cutoffAt: Date
    let endsAt: Date
    /// Whole seconds from now to ``cutoffAt``, 0 once it has passed: the cutoff timer's sleep.
    let secondsToCutoff: Int
  }

  struct Required: Sendable, Equatable, Encodable {
    let task: String
    let appPath: String
  }
}

/// Why `build next` can't tell which tasks the app target needs. Never read as "none needed":
/// that would let the budget skip the task that makes the app compile.
enum AppTargetPackagesError: Error, Sendable, Equatable, CustomStringConvertible {
  case noConfig
  case config(String)
  case packages(ModuleGraphLoadError)

  var description: String {
    switch self {
    case .noConfig: "no \(ConfigLoader.fileName) to read the packages globs from"
    case .config(let reason): reason
    case .packages(let error): error.description
    }
  }
}

/// The repository's package directories, from `.swiftgate.toml`'s `packages` globs: every
/// `.swift` file outside them belongs to the app target.
enum AppTargetPackages {
  static func directories(root: URL) -> Result<[String], AppTargetPackagesError> {
    let config: Config
    switch StaticCheckInputs.loadConfig(root: root) {
    case .success(let loaded?): config = loaded
    case .success(nil): return .failure(.noConfig)
    case .failure(let failure):
      switch failure.outcome {
      case .invalid(let reason, _), .blocked(let reason): return .failure(.config(reason))
      default: return .failure(.config("\(ConfigLoader.fileName) failed to load"))
      }
    }
    do throws(ModuleGraphLoadError) {
      return .success(try PackageDirectories.resolve(globs: config.packages, root: root))
    } catch {
      return .failure(.packages(error))
    }
  }

  static func required(ledger: Ledger, root: URL)
    -> Result<BuildScheduler.RequiredTasks, AppTargetPackagesError>
  {
    directories(root: root).map {
      BuildScheduler.RequiredTasks(ledger: ledger, packageDirectories: $0)
    }
  }
}

enum BuildNextRun {
  static func run(
    slug: String, session: String?, git: any Git, clock: any BuildClock, root: URL
  ) async
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
      let run: BuildRunStore
      let record: BuildRunRecord
      do throws(BuildRunStoreError) {
        guard let latest = try await BuildRunStore.latest(plan: slug, git: git) else {
          return .blocked(
            command, slug,
            "plan `\(slug)` has no build run under \(plan.buildDirectory); run "
              + "`swiftgate build start \(slug) --preset <name> --session <id>` first")
        }
        run = latest
      } catch {
        return .blocked(command, slug, "listing \(plan.buildDirectory): \(error)")
      }
      let runID = run.runID
      do {
        record = try run.record()
      } catch {
        return .blocked(command, slug, "reading build run \(runID): \(error)")
      }
      let ledger = try BuildLoop.ledger(plan)
      let required: BuildScheduler.RequiredTasks
      switch record.preset.profile {
      case .brownfield:
        // A brownfield plan's contract commit compiles before any task starts, so no task is
        // what the build waits on to compile, and there are no package globs to read.
        required = .empty
      case .owned:
        switch AppTargetPackages.required(ledger: ledger, root: root) {
        case .success(let found): required = found
        case .failure(let error):
          return .blocked(
            command, slug, "can't tell which tasks the app target needs to compile: \(error)")
        }
      }
      let running = Set(ledger.tasks.filter { $0.status == .inProgress }.map(\.id))
      let now = clock.now()
      let result = BuildScheduler.next(
        ledger: ledger, running: running, preset: record.preset, startedAt: record.startedAt,
        now: now, required: required, timeBox: record.timeBox)
      let notDone = Set(ledger.tasks.filter { $0.status != .done }.map(\.id))
      let report = BuildNextReport(
        runId: runID, phase: result.phase, toStart: result.toStart, running: result.running,
        refused: result.refused.map {
          BuildNextReport.Refused(task: $0.taskID, reason: Self.reason($0.reason))
        },
        required: required.tasks.filter { notDone.contains($0.taskID) }.map {
          BuildNextReport.Required(task: $0.taskID, appPath: $0.appPath)
        }, stallMin: record.preset.stallMin,
        timeBox: record.timeBox.map { box in
          let deadlines = box.deadlines
          return BuildNextReport.TimeBox(
            noNewStartsAt: deadlines.noNewStartsAt, cutoffAt: deadlines.cutoffAt,
            endsAt: deadlines.endsAt,
            secondsToCutoff: max(0, Int(deadlines.cutoffAt.timeIntervalSince(now).rounded(.up))))
        })
      return BuildLoopResult(
        command: command, plan: slug, verdict: .green, report: report, holder: nil,
        message: "phase \(result.phase.rawValue)")
    } catch {
      return .blocked(command, slug, error.message)
    }
  }

  private static func reason(_ reason: BuildScheduler.RefusalReason) -> String {
    switch reason {
    case .missingModel: "missing-model"
    case .unpinnedModel: "unpinned-model"
    }
  }

  static func render(_ result: BuildLoopResult<BuildNextReport>, format: OutputFormat) -> String {
    BuildLoop.render(result, format: format) { report in
      func list(_ ids: [String]) -> String { ids.isEmpty ? "none" : ids.joined(separator: ", ") }
      var line =
        "build next: run \(report.runId), phase \(report.phase.rawValue); start: "
        + "\(list(report.toStart)); running: \(list(report.running))"
      if let box = report.timeBox {
        line += "; \(box.secondsToCutoff) s to the cutoff"
      }
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
      slug: plan, session: session, git: BuildLoop.git(), clock: LiveBuildClock(),
      root: URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory))
    Console.write(BuildNextRun.render(result, format: output.format))
    try BuildLoop.exit(result)
  }
}

import ArgumentParser
import Foundation
import SwiftGateDomain

/// What `plan-schedule` found: the recomputed waves, or why it couldn't compute them. `plan-lint`
/// (a later task) calls ``PlanSchedule/schedule(tasks:maxParallel:)`` directly rather than
/// shelling out to this command; this report is for a human or the decomposer skill reading the
/// command's own output.
struct PlanScheduleReport: Sendable, Equatable, Encodable {
  let command = "plan-schedule"
  let verdict: Verdict
  let ledger: String
  var waves: [[String]]?
  var cycle: [String]?
  var missingDependencyTask: String?
  var missingDependencyOn: String?
  let message: String

  private enum CodingKeys: String, CodingKey {
    case command, verdict, ledger, waves, cycle, missingDependencyTask, missingDependencyOn,
      message
  }

  static func render(_ report: PlanScheduleReport, format: OutputFormat) -> String {
    switch format {
    case .json:
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      let data = (try? encoder.encode(report)) ?? Data()
      return String(decoding: data, as: UTF8.self)
    case .human:
      return "plan-schedule: \(report.message)"
    }
  }
}

/// The deterministic body of `plan-schedule`, factored out of the `ParsableCommand` so it's
/// testable without going through argument parsing or stdout.
enum PlanScheduleRun {
  static func run(ledgerPath: String) -> PlanScheduleReport {
    let data: Data
    do {
      data = try Data(contentsOf: URL(filePath: ledgerPath))
    } catch {
      return blocked(
        ledgerPath: ledgerPath,
        message: "can't read `\(ledgerPath)`: \(error.localizedDescription)")
    }

    let ledger: Ledger
    do {
      ledger = try LedgerJSON.decode(data)
    } catch {
      return blocked(
        ledgerPath: ledgerPath, message: "`\(ledgerPath)` is not a valid ledger.json: \(error)")
    }

    switch PlanSchedule.schedule(tasks: ledger.tasks, maxParallel: ledger.maxParallel) {
    case .success(let waves):
      let waveCount = waves.count
      return PlanScheduleReport(
        verdict: .green, ledger: ledgerPath, waves: waves,
        message: waveCount == 1 ? "1 wave" : "\(waveCount) waves")
    case .failure(.cycle(let ids)):
      let chain = (ids + [ids[0]]).joined(separator: " -> ")
      return PlanScheduleReport(
        verdict: .red, ledger: ledgerPath, cycle: ids,
        message: "dependency cycle: \(chain)")
    case .failure(.missingDependency(let task, let dependency)):
      return PlanScheduleReport(
        verdict: .red, ledger: ledgerPath, missingDependencyTask: task,
        missingDependencyOn: dependency,
        message: "task '\(task)' depends on unknown task '\(dependency)'")
    }
  }

  private static func blocked(ledgerPath: String, message: String) -> PlanScheduleReport {
    PlanScheduleReport(verdict: .blocked, ledger: ledgerPath, message: message)
  }
}

struct PlanScheduleCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "plan-schedule",
    abstract: "Schedule ledger tasks into Kahn topological waves, split by disjoint write sets.",
    discussion:
      "Reads a ledger.json-shaped file (schemaVersion, resume, maxParallel, tasks, waves — its "
      + "own `waves` field is ignored, never trusted) and recomputes `waves` from `tasks` and "
      + "`maxParallel` (spec §6.2): Kahn topological layers by dependency depth, then within "
      + "each layer a greedy id-ascending first fit so two tasks whose write sets overlap never "
      + "share a wave, capped at `maxParallel` tasks per wave. Exit 0 with the waves. Exit 1, "
      + "naming the task ids involved, on a dependency cycle or a dependency naming a task not "
      + "in the ledger. Exit 2 when the file can't be read or isn't a valid ledger.json. "
      + "Ledgers live in the plan-state directory, not the working directory, so <ledger> is "
      + "required — a cwd default would silently read the wrong file, or none.")

  @Argument(help: "Path to a ledger.json-shaped file.")
  var ledger: String

  @OptionGroup var output: OutputOptions

  func run() throws {
    let report = PlanScheduleRun.run(ledgerPath: ledger)
    Console.write(PlanScheduleReport.render(report, format: output.format))
    if report.verdict != .green { throw ExitCode(report.verdict.exitCode) }
  }
}

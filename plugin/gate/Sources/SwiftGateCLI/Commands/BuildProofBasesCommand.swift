import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

struct BuildProofBasesReport: Sendable, Equatable, Encodable {
  let command: String
  let plan: String
  let runId: String
  /// The plan's surface commit when `plan.json` records one, then each merged task's surface
  /// commit in the order the tasks reached `main`, each sha once.
  let proofBases: [String]
  /// `proofBases` as `check` arguments: `--proof-base <sha>` each.
  let arguments: String
}

/// The final gate's proof bases: `prove` retries a test that only fails to compile at the merge
/// base at the plan's surface, then at the surface commit of the task that added the API it calls.
enum BuildProofBasesRun {
  static func run(slug: String, git: any Git) async -> BuildLoopResult<BuildProofBasesReport> {
    let command = "build proof-bases"
    let plan: PlanStateLayout.Plan
    do {
      plan = try await BuildLoop.planLayout(slug, git: git).plan(slug)
    } catch {
      return .blocked(command, slug, "invalid plan name `\(slug)`: \(error)")
    }
    let store: BuildRunStore
    let log: BuildEventLog
    do throws(BuildRunStoreError) {
      guard let latest = try await BuildRunStore.latest(plan: slug, git: git) else {
        return .blocked(
          command, slug, "plan `\(slug)` has no build run under \(plan.buildDirectory)")
      }
      store = latest
      log = try store.events()
    } catch {
      return .blocked(command, slug, "reading the build run: \(error)")
    }
    guard log.damage.isEmpty else {
      return .blocked(command, slug, "\(store.layout.eventsFile) is damaged: \(log.damage)")
    }
    let planSurface: String?
    var notes: [String] = []
    do throws(PlanStateStoreError) {
      planSurface = try PlanStateStore(plan: plan).planFile().surfaceCommit
    } catch .missing(let path) {
      // A run's merged returns still name every task surface, so only the plan's is unknown.
      planSurface = nil
      notes.append("\(path) is missing, so no plan surface leads the list")
    } catch {
      return .blocked(command, slug, "reading the plan's surface commit: \(error)")
    }
    var proofBases: [String] = planSurface.map { [$0] } ?? []
    for task in log.mergedTasks {
      let path = store.layout.directory + "/returns/\(task).json"
      let taskReturn: TaskReturn
      do {
        taskReturn = try TaskReturnJSON.decode(Data(contentsOf: URL(filePath: path)))
      } catch {
        return .blocked(
          command, slug, "merged task `\(task)` has no readable stored return at \(path): \(error)")
      }
      if let surface = taskReturn.surfaceCommit, !proofBases.contains(surface) {
        proofBases.append(surface)
      }
    }
    let arguments = proofBases.map { "--proof-base \($0)" }.joined(separator: " ")
    return BuildLoopResult(
      command: command, plan: slug, verdict: .green,
      report: BuildProofBasesReport(
        command: command, plan: slug, runId: store.runID, proofBases: proofBases,
        arguments: arguments),
      holder: nil,
      message: ([proofBases.isEmpty ? "no merged task has a surface commit" : arguments] + notes)
        .joined(separator: "; "))
  }

  static func render(_ result: BuildLoopResult<BuildProofBasesReport>, format: OutputFormat)
    -> String
  {
    BuildLoop.render(result, format: format) { report in
      report.proofBases.isEmpty ? "build proof-bases: none" : report.arguments
    }
  }
}

struct BuildProofBasesCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "proof-bases",
    abstract:
      "Print the final gate's --proof-base arguments: the plan's surface, then each merged "
      + "task's surface commit.",
    discussion:
      "Reads plan.json's surfaceCommit, then the plan's newest build run: the tasks its merges "
      + "left on main, in merge order, and each one's stored return. Each sha appears once. Pass "
      + "the output to `swiftgate check --tier ready`. Exits 0, or 2 when plan.json, the run, its "
      + "event log or a merged task's stored return can't be read.")

  @Argument(help: "The plan's slug.")
  var plan: String

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let result = await BuildProofBasesRun.run(slug: plan, git: BuildLoop.git())
    Console.write(BuildProofBasesRun.render(result, format: output.format))
    try BuildLoop.exit(result)
  }
}

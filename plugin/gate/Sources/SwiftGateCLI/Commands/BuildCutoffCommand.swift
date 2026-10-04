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

  static func run(
    slug: String, session: String?, git: any Git, clock: any BuildClock,
    telemetry: BuildCutoffTelemetry?
  ) async -> BuildLoopResult<BuildCutoffReport> {
    .blocked(command, slug, "build cutoff isn't available yet")
  }

  static func render(_ result: BuildLoopResult<BuildCutoffReport>, format: OutputFormat) -> String {
    BuildLoop.render(result, format: format) { report in
      "build cutoff: run \(report.runId); finish: \(report.finish.joined(separator: ", "))"
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
      + "the decisions to the run's cutoff.json. Exits 0 when it decided, 1 when --session "
      + "doesn't hold the plan's lock or the cutoff hasn't come, and 2 for an owned run, a "
      + "missing --session or unreadable plan state.")

  @Argument(help: "The plan's slug.")
  var plan: String

  @Option(help: "The session id holding the plan's lock (from the SessionStart context).")
  var session: String?

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let result = await BuildCutoffRun.run(
      slug: plan, session: session, git: BuildLoop.git(), clock: LiveBuildClock(),
      telemetry: nil)
    Console.write(BuildCutoffRun.render(result, format: output.format))
    try BuildLoop.exit(result)
  }
}

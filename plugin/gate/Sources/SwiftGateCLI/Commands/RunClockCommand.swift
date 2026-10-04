import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// Where a `swiftgate run` stands in its time box.
struct RunClockReport: Sendable, Equatable, Encodable {
  let command: String
  let plan: String
  let startedAt: Date
  let now: Date
  let elapsedSeconds: Int
  let budgetMin: Int
  let source: TimeBoxSource
  let phase: BudgetPhase
  let deadlines: RunTimeBox.Deadlines
  /// The first deadline not yet passed, and the whole seconds left to it; `nil` once the box has
  /// ended.
  let next: Next?

  struct Next: Sendable, Equatable, Encodable {
    let deadline: String
    let secondsLeft: Int
  }
}

/// `run clock`'s behaviour, apart from argument parsing so tests drive it against a temp clone.
enum RunClockRun {
  static let command = "run clock"

  /// The outcome: the report, or the message and exit status of a refusal.
  enum Outcome: Sendable, Equatable {
    case report(RunClockReport)
    case refused(message: String, status: Int32)
  }

  static func run(slug: String, root: URL, runner: any ProcessRunner, now: Date) async -> Outcome {
    .refused(message: "run clock isn't available yet", status: 2)
  }

  static func render(_ outcome: Outcome, json: Bool) -> String {
    switch outcome {
    case .refused(let message, _): return "\(command): \(message)"
    case .report(let report):
      guard json else { return "\(command): \(report.plan) \(report.phase.rawValue)" }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      encoder.dateEncodingStrategy = .iso8601
      return String(decoding: (try? encoder.encode(report)) ?? Data(), as: UTF8.self)
    }
  }
}

/// `swiftgate run clock <slug>`: the run's time box, its deadlines and the time left to each.
struct RunClockCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "clock",
    abstract: "Print where a brownfield run stands in its time box.",
    discussion:
      "Reads the plan's clock.json, which `swiftgate run` wrote at launch. Exits 0 with the "
      + "report, and 2 for a plan with no clock or a clock with no time box.")

  @Argument(help: "The plan's slug.")
  var slug: String

  @Flag(help: "Print JSON.")
  var json = false

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let outcome = await RunClockRun.run(
      slug: slug, root: root, runner: LiveProcessRunner(), now: Date())
    Console.write(RunClockRun.render(outcome, json: json))
    if case .refused(_, let status) = outcome { throw ExitCode(status) }
  }
}

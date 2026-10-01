import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// What an `events` command prints and the status it exits with.
struct EventsCommandOutput: Equatable {
  let stdout: String
  let stderr: String
  let status: Int32
}

/// The flags every `events` reader shares, checked into a query.
enum EventsQueryInput {
  /// The query; throws the line `command` prints before exiting 2.
  static func query(
    command: String, kinds: [HarnessEventKind], since: String?, runID: String?,
    buildRunID: String?, now: Date
  ) throws(EventsQueryInputError) -> EventQuery {
    EventQuery()
  }
}

struct EventsQueryInputError: Error, Equatable {
  let message: String
}

/// `events list`: every matching event as 1 JSON line, oldest first; damage on stderr.
enum EventsListRun {
  static func make(files: any EventStoreFileReading, query: EventQuery) -> EventsCommandOutput {
    EventsCommandOutput(stdout: "", stderr: "", status: 0)
  }
}

/// `events summary`: every registered section over the matching events.
enum EventsSummaryRun {
  static func make(
    files: any EventStoreFileReading, query: EventQuery, json: Bool, now: Date,
    sections: [any EventSummarySection] = EventSummary.sections
  ) -> EventsCommandOutput {
    EventsCommandOutput(stdout: "", stderr: "", status: 0)
  }
}

extension HarnessEventKind: ExpressibleByArgument {}

struct EventsCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "events",
    abstract: "Read the harness's events from every store under .harness/events/.",
    subcommands: [EventsListCommand.self, EventsSummaryCommand.self])
}

struct EventsListCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "Print matching events as JSON lines, oldest first.",
    discussion:
      "Reads active files, sealed segments and imported stores, each event once. Damage is "
      + "listed on stderr by file and line. Exit 0 printed, even with damage; 2 for a bad "
      + "--since or --run.")

  @Option(help: "Only this kind; repeat for several. Every kind when omitted.")
  var kind: [HarnessEventKind] = []

  @Option(help: "Only events at or after this: 7d, 12h, 30m, an ISO 8601 time or a run id.")
  var since: String?

  @Option(name: .customLong("run"), help: "Only events of this gate run id.")
  var runID: String?

  func run() throws {}
}

struct EventsSummaryCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "summary",
    abstract: "Summarize the events: cost, gate time, wrong gates, tests, hooks, caches, halts, "
      + "the judge and the store.",
    discussion:
      "A section with no events says so. Damage is listed by file and line. Exit 0 printed, "
      + "even with damage; 2 for a bad --since, --run or --build-run.")

  @Option(help: "Only events at or after this: 7d, 12h, 30m, an ISO 8601 time or a run id.")
  var since = "7d"

  @Option(name: .customLong("run"), help: "Only events of this gate run id.")
  var runID: String?

  @Option(name: .customLong("build-run"), help: "Join sections to this build run id.")
  var buildRunID: String?

  @Flag(help: "Print the summary as JSON.")
  var json = false

  func run() throws {}
}

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
    func refused(_ why: String) -> EventsQueryInputError {
      EventsQueryInputError(message: "swiftgate \(command): \(why)")
    }
    var start: Date?
    if let since {
      guard let parsed = EventQuery.since(since, now: now) else {
        throw refused(
          "--since \(since) is not a duration such as 7d, 12h or 30m, an ISO 8601 time or a run id")
      }
      start = parsed
    }
    if let runID, !RunID.isValid(runID) { throw refused("--run \(runID) is not a run id") }
    if let buildRunID, !RunID.isValid(buildRunID) {
      throw refused("--build-run \(buildRunID) is not a build run id")
    }
    return EventQuery(
      kinds: kinds.isEmpty ? nil : Set(kinds), since: start, runID: runID, buildRunID: buildRunID)
  }
}

struct EventsQueryInputError: Error, Equatable {
  let message: String
}

/// `events list`: every matching event as 1 JSON line, oldest first; damage on stderr.
enum EventsListRun {
  static func make(files: any EventStoreFileReading, query: EventQuery) -> EventsCommandOutput {
    let read = EventStoreReader(files: files).read(query)
    var stdout = Data()
    do {
      for stored in read.events { stdout.append(try HarnessEventJSON.encodeLine(stored.event)) }
    } catch {
      return EventsCommandOutput(
        stdout: "", stderr: "swiftgate events list: could not encode an event: \(error)\n",
        status: 2)
    }
    return EventsCommandOutput(
      stdout: String(decoding: stdout.dropLast(), as: UTF8.self),
      stderr: EventsDamage.lines(read.damage, command: "events list"), status: 0)
  }
}

/// `events summary`: every registered section over the matching events.
enum EventsSummaryRun {
  static func make(
    files: any EventStoreFileReading, query: EventQuery, json: Bool, now: Date,
    sections: [any EventSummarySection] = EventSummary.sections
  ) -> EventsCommandOutput {
    let read = EventStoreReader(files: files).read(query)
    let report = EventSummary.make(
      EventSummaryInput(
        events: read.events, query: query, store: read.facts, damage: read.damage, files: files,
        now: now),
      sections: sections)
    guard json else {
      return EventsCommandOutput(stdout: report.render(), stderr: "", status: 0)
    }
    do {
      return EventsCommandOutput(
        stdout: String(decoding: try report.encoded(), as: UTF8.self),
        stderr: EventsDamage.lines(read.damage, command: "events summary"), status: 0)
    } catch {
      return EventsCommandOutput(
        stdout: "", stderr: "swiftgate events summary: could not encode the summary: \(error)\n",
        status: 2)
    }
  }
}

/// Damage on stderr, 1 line per damaged line or file, so it's never dropped unannounced.
enum EventsDamage {
  static func lines(_ damage: [EventDamage], command: String) -> String {
    damage.map { "swiftgate \(command): damage: \($0)\n" }.joined()
  }
}

/// Prints an `events` command's output and exits with its status.
enum EventsCommandRunner {
  static var root: URL {
    URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
  }

  static func finish(_ output: EventsCommandOutput) throws {
    if !output.stderr.isEmpty { FileHandle.standardError.write(Data(output.stderr.utf8)) }
    if !output.stdout.isEmpty { Console.write(output.stdout) }
    if output.status != 0 { throw ExitCode(output.status) }
  }

  static func query(
    command: String, kinds: [HarnessEventKind], since: String?, runID: String?,
    buildRunID: String?
  ) throws -> EventQuery {
    do throws(EventsQueryInputError) {
      return try EventsQueryInput.query(
        command: command, kinds: kinds, since: since, runID: runID, buildRunID: buildRunID,
        now: Date())
    } catch {
      FileHandle.standardError.write(Data("\(error.message)\n".utf8))
      throw ExitCode(2)
    }
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

  func run() throws {
    let query = try EventsCommandRunner.query(
      command: "events list", kinds: kind, since: since, runID: runID, buildRunID: nil)
    try EventsCommandRunner.finish(
      EventsListRun.make(files: LiveEventStoreFiles(root: EventsCommandRunner.root), query: query))
  }
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

  func run() throws {
    let query = try EventsCommandRunner.query(
      command: "events summary", kinds: [], since: since, runID: runID, buildRunID: buildRunID)
    try EventsCommandRunner.finish(
      EventsSummaryRun.make(
        files: LiveEventStoreFiles(root: EventsCommandRunner.root), query: query, json: json,
        now: Date()))
  }
}

import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// What `judge events` prints and the status it exits with.
struct JudgeEventsReport: Equatable {
  let stdout: String
  let stderr: String
  let status: Int32

  /// Reads the judge stream, the checkout's every store or 1 run's copy, and summarizes what
  /// `filter` keeps.
  /// - Parameters:
  ///   - files: the checkout's event stores: its own `.harness/events/` and every import of a
  ///     removed worktree's, each event once by `eventID`.
  ///   - reader: 1 run's copy, read for `runID`.
  static func make(
    files: any EventStoreFileReading, reader: any HarnessEventReading, runID: String?,
    filter: JudgeEventFilter, json: Bool
  ) -> JudgeEventsReport {
    let path = reader.path(.judge, runID: runID)
    func refused(_ why: String) -> JudgeEventsReport {
      JudgeEventsReport(stdout: "", stderr: "swiftgate judge events: \(why)\n", status: 2)
    }
    let read: HarnessEventJSON.Read
    var notes = ""
    if let runID {
      let data: Data?
      do throws(HarnessEventReadError) {
        data = try reader.read(.judge, runID: runID)
      } catch {
        return refused("\(error)")
      }
      do throws(HarnessEventDecodeError) {
        read = try HarnessEventJSON.decode(data ?? Data())
      } catch {
        return refused("\(path): \(error)")
      }
      if data == nil { notes += "swiftgate judge events: no \(path) yet\n" }
      if read.tornLastLine {
        notes += "swiftgate judge events: \(path) ends in a torn line, left out\n"
      }
    } else {
      let judgeKinds = Set(HarnessEventKind.allCases.filter { $0.stream == .judge })
      let stores = EventStoreReader(files: files).read(EventQuery(kinds: judgeKinds))
      var torn = false
      for damage in stores.damage {
        switch damage.kind {
        case .tornLastLine:
          torn = true
          notes += "swiftgate judge events: \(damage.file) ends in a torn line, left out\n"
        case .unreadableIndex:
          notes += "swiftgate judge events: \(damage), so its segment was read whole\n"
        case .undecodableLine, .unreadableFile:
          return refused("\(damage)")
        }
      }
      let judge = stores.facts.streams.first { $0.stream == .judge }
      if (judge?.activeBytes ?? 0) == 0, (judge?.sealedSegments ?? 0) == 0 {
        notes += "swiftgate judge events: no \(path) yet\n"
      }
      read = HarnessEventJSON.Read(events: stores.events.map(\.event), tornLastLine: torn)
    }
    let summary = JudgeEventSummary.make(read, filter: filter)
    guard json else {
      return JudgeEventsReport(stdout: summary.render(source: path), stderr: notes, status: 0)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    do {
      return JudgeEventsReport(
        stdout: String(decoding: try encoder.encode(summary), as: UTF8.self), stderr: notes,
        status: 0)
    } catch {
      return refused("could not encode the summary: \(error)")
    }
  }
}

extension HarnessRoute: ExpressibleByArgument {}

struct JudgeEventsCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "events",
    abstract:
      "Summarize the judge's decisions and calls from .harness/events/, removed worktrees' "
      + "imported copies included.",
    discussion:
      "Exit 0 printed; 2 for an unreadable log, an unknown key, a newer schemaVersion or a bad "
      + "--since or --run; a torn last line is reported on stderr and left out.")

  @Option(help: "Only events at or after this run id's start, or this ISO 8601 time.")
  var since: String?

  @Option(
    name: .customLong("run"),
    help: "Read this run's own copy, .harness/runs/<id>/events/judge.jsonl.")
  var runID: String?

  @Option(help: "Only events from this route, such as check-ready or bench.")
  var route: HarnessRoute?

  @Option(help: "Only decisions first asked of, and calls to, this backend.")
  var backend: JudgeBackend?

  @Flag(help: "Print the summary as JSON.")
  var json = false

  func run() throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    var start: Date?
    if let since {
      guard let parsed = JudgeEventFilter.since(since) else {
        FileHandle.standardError.write(
          Data("swiftgate judge events: --since \(since) is not a run id or ISO 8601 time\n".utf8))
        throw ExitCode(2)
      }
      start = parsed
    }
    let report = JudgeEventsReport.make(
      files: LiveEventStoreFiles(root: root), reader: HarnessEventFiles(root: root), runID: runID,
      filter: JudgeEventFilter(since: start, route: route, backend: backend), json: json)
    if !report.stderr.isEmpty { FileHandle.standardError.write(Data(report.stderr.utf8)) }
    if !report.stdout.isEmpty { Console.write(report.stdout) }
    if report.status != 0 { throw ExitCode(report.status) }
  }
}

import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// `events span start` and `events span end` against 1 checkout's store, with the config
/// already read.
enum SpanRun {
  typealias Output = BuildHaltRun.Output

  /// - Parameters:
  ///   - enabled: `.swiftgate.toml`'s `[telemetry] enabled`; `false` records nothing.
  static func start(
    log: SpanLog, enabled: Bool, phase: String, buildRun: String, task: String?, role: String?,
    parent: String?
  ) -> Output {
    Output(stdout: "", stderr: "", status: 0)
  }

  static func end(log: SpanLog, enabled: Bool, spanID: String, outcome: String) -> Output {
    Output(stdout: "", stderr: "", status: 0)
  }

  /// `start` against the main checkout of the repository `directory` is in.
  static func start(
    in directory: String, phase: String, buildRun: String, task: String?, role: String?,
    parent: String?
  ) async -> Output {
    Output(stdout: "", stderr: "", status: 0)
  }

  /// `end` against the main checkout of the repository `directory` is in.
  static func end(in directory: String, spanID: String, outcome: String) async -> Output {
    Output(stdout: "", stderr: "", status: 0)
  }
}

/// `swiftgate events span start|end`: records a run phase no other event times.
struct EventsSpanCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "span",
    abstract: "Record the start or end of a run phase.",
    subcommands: [EventsSpanStartCommand.self, EventsSpanEndCommand.self])
}

/// `events span start --phase <phase> --build-run <id> [--task <id>] [--role <role>]
/// [--parent <span id>]`: prints the new span id.
struct EventsSpanStartCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "start",
    abstract: "Record a span's start and print its id.")

  @Option(
    help:
      "The phase: spec-read, discover, explore, plan, contract, worker, review, verify, fix, final or ship."
  )
  var phase: String

  @Option(help: "The build run id.")
  var buildRun: String

  @Option(help: "The task the span works on.")
  var task: String?

  @Option(help: "The agent role doing the work.")
  var role: String?

  @Option(help: "The enclosing span's id.")
  var parent: String?

  func run() throws {
    try StubCommand.notImplemented("events span start", json: false)
  }
}

/// `events span end <span id> --outcome <outcome>`: reads the span's start and records its end.
struct EventsSpanEndCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "end",
    abstract: "Record a span's end.")

  @Argument(help: "The id `events span start` printed.")
  var spanID: String

  @Option(help: "ok, red, halted or abandoned.")
  var outcome: String

  func run() throws {
    try StubCommand.notImplemented("events span end", json: false)
  }
}

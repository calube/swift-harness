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
    let command = "events span start"
    guard let phaseValue = SpanPhase(rawValue: phase) else {
      return refused(command, "--phase \(phase) is not one of \(allowed(SpanPhase.self))")
    }
    if !RunID.isValid(buildRun) {
      return refused(command, "--build-run \(buildRun) is not a build run id")
    }
    if let task, !RunID.isValid(task) {
      return refused(command, "--task \(task) is not a task id")
    }
    var roleValue: AgentRole?
    if let role {
      guard let parsed = AgentRole(rawValue: role) else {
        return refused(command, "--role \(role) is not one of \(allowed(AgentRole.self))")
      }
      roleValue = parsed
    }
    if let parent, !SpanStartEvent.isValidID(parent) {
      return refused(command, "--parent \(parent) is not a span id")
    }
    if !enabled { return telemetryOff(command) }
    do throws(SpanLogError) {
      let event = try log.start(
        phase: phaseValue, buildRun: buildRun, task: task, role: roleValue, parentSpan: parent)
      guard case .spanStart(let start) = event.payload else {
        return Output(stdout: "", stderr: "swiftgate \(command): wrote no span.start\n", status: 2)
      }
      return Output(stdout: start.spanID, stderr: "", status: 0)
    } catch {
      return failed(command, error)
    }
  }

  static func end(log: SpanLog, enabled: Bool, spanID: String, outcome: String) -> Output {
    let command = "events span end"
    if !SpanStartEvent.isValidID(spanID) {
      return refused(command, "\(spanID) is not a span id")
    }
    guard let outcomeValue = SpanOutcome(rawValue: outcome) else {
      return refused(command, "--outcome \(outcome) is not one of \(allowed(SpanOutcome.self))")
    }
    if !enabled { return telemetryOff(command) }
    do throws(SpanLogError) {
      let event = try log.end(spanID: spanID, outcome: outcomeValue)
      let milliseconds: String =
        switch event.payload {
        case .spanEnd(let end): " after \(end.milliseconds) ms"
        default: ""
        }
      return Output(
        stdout: "\(command): recorded \(outcome) for span \(spanID)\(milliseconds)", stderr: "",
        status: 0)
    } catch {
      return failed(command, error)
    }
  }

  /// `start` against the main checkout of the repository `directory` is in.
  static func start(
    in directory: String, phase: String, buildRun: String, task: String?, role: String?,
    parent: String?
  ) async -> Output {
    switch await BuildHaltRun.store(command: "events span start", directory: directory) {
    case .refused(let output): output
    case .found(let root, let enabled):
      start(
        log: SpanLog(root: root), enabled: enabled, phase: phase, buildRun: buildRun, task: task,
        role: role, parent: parent)
    }
  }

  /// `end` against the main checkout of the repository `directory` is in.
  static func end(in directory: String, spanID: String, outcome: String) async -> Output {
    switch await BuildHaltRun.store(command: "events span end", directory: directory) {
    case .refused(let output): output
    case .found(let root, let enabled):
      end(log: SpanLog(root: root), enabled: enabled, spanID: spanID, outcome: outcome)
    }
  }

  private static func allowed<Value: CaseIterable & RawRepresentable>(_: Value.Type) -> String
  where Value.RawValue == String {
    Value.allCases.map(\.rawValue).joined(separator: ", ")
  }

  private static func refused(_ command: String, _ why: String) -> Output {
    Output(stdout: "", stderr: "swiftgate \(command): \(why)\n", status: 2)
  }

  private static func telemetryOff(_ command: String) -> Output {
    Output(
      stdout: "",
      stderr: "swiftgate \(command): telemetry is off in .swiftgate.toml; nothing recorded\n",
      status: 0)
  }

  private static func failed(_ command: String, _ error: SpanLogError) -> Output {
    switch error {
    case .noStart, .alreadyEnded:
      Output(stdout: "", stderr: "swiftgate \(command): \(error); nothing recorded\n", status: 1)
    case .unreadable, .unwritten:
      Output(stdout: "", stderr: "swiftgate \(command): not recorded: \(error)\n", status: 2)
    }
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
struct EventsSpanStartCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "start",
    abstract: "Record a span's start and print its id.",
    discussion:
      "Writes span.start to the main checkout's span stream, whichever worktree the command "
      + "starts in, and prints the new 16-hex span id alone on stdout. Exit 0 recorded, or "
      + "nothing to record with [telemetry] enabled = false; 2 for a phase or role outside "
      + "its list, a --build-run, --task or --parent that isn't an id, or a store that can't "
      + "be read or written.")

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

  func run() async throws {
    try BuildHaltRun.finish(
      await SpanRun.start(
        in: FileManager.default.currentDirectoryPath, phase: phase, buildRun: buildRun,
        task: task, role: role, parent: parent))
  }
}

/// `events span end <span id> --outcome <outcome>`: reads the span's start and records its end.
struct EventsSpanEndCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "end",
    abstract: "Record a span's end.",
    discussion:
      "Reads the span's span.start from the main checkout's span stream and writes span.end "
      + "with that start as its parent and ms from its time to now. Exit 0 recorded, or nothing "
      + "to record with [telemetry] enabled = false; 1 when no start has the id or the span "
      + "already ended, writing nothing; 2 for an id that isn't a span id, an outcome outside "
      + "its list, or a store that can't be read or written.")

  @Argument(help: "The id `events span start` printed.")
  var spanID: String

  @Option(help: "ok, red, halted or abandoned.")
  var outcome: String

  func run() async throws {
    try BuildHaltRun.finish(
      await SpanRun.end(
        in: FileManager.default.currentDirectoryPath, spanID: spanID, outcome: outcome))
  }
}

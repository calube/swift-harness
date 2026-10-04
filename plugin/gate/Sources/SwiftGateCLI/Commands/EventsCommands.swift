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
    let read = EventStoreReader(files: files).read(query, sealedTests: .indexesWhereRolledUp)
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

extension EventsSummaryRun {
  /// Every registered section, with wrong gates and halts joined to `builds`.
  static func sections(builds: BuildJoin) -> [any EventSummarySection] {
    EventSummary.sections.map {
      switch $0.id {
      case .wrongGates: WrongGatesSection(builds: builds)
      case .halts: HaltsSection(builds: builds)
      default: $0
      }
    }
  }

  /// The build state under the git common dir; a common dir git can't name is damage.
  static func builds(buildRunID: String?) async -> BuildJoin {
    do {
      let common = try await BuildLoop.git().commonDirectory()
      return BuildJoinReader(commonDirectory: URL(filePath: common, directoryHint: .isDirectory))
        .read(buildRunID: buildRunID)
    } catch {
      return BuildJoin(
        source: BuildJoinReader.plansDirectory, runs: [],
        damage: [
          BuildJoinDamage(
            path: BuildJoinReader.plansDirectory, reason: "no git common dir: \(error)")
        ])
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
    abstract:
      "Read the harness's events from every store under .harness/events/, and ingest agent usage.",
    subcommands: [
      EventsListCommand.self, EventsSummaryCommand.self, EventsIngestCommand.self,
      EventsSpanCommand.self,
    ])
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

struct EventsSummaryCommand: AsyncParsableCommand {
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

  func run() async throws {
    let query = try EventsCommandRunner.query(
      command: "events summary", kinds: [], since: since, runID: runID, buildRunID: buildRunID)
    let builds = await EventsSummaryRun.builds(buildRunID: buildRunID)
    try EventsCommandRunner.finish(
      EventsSummaryRun.make(
        files: LiveEventStoreFiles(root: EventsCommandRunner.root), query: query, json: json,
        now: Date(), sections: EventsSummaryRun.sections(builds: builds)))
  }
}

/// `events ingest`: each assistant message of a session's transcripts as 1 `agent.usage`, and each
/// agent's tool calls per window as 1 `agent.tools`.
enum EventsIngestRun {
  struct Options: Equatable {
    var session: String
    var workflowTranscripts: String?
    var role: AgentRole?
    var task: String?
    var buildRun: String?
    var agentID: String? = nil
  }

  static let command = "swiftgate events ingest"

  /// Exit 0 with what was stored; 2 for telemetry off, no config, a bad flag value, an unreadable
  /// session record or transcript, a malformed usage line, or a failed write.
  static func make(options: Options, root: URL, prices: ModelPriceTable = .current)
    -> EventsCommandOutput
  {
    func refused(_ why: String, stderr: String = "") -> EventsCommandOutput {
      EventsCommandOutput(stdout: "", stderr: stderr + "\(command): \(why)\n", status: 2)
    }
    switch TelemetryOptIn.enabled(root: root) {
    case .success(nil):
      return refused("no .swiftgate.toml here; ingest records events only in a project")
    case .failure(let failure):
      return refused("the config can't be read: \(failure.outcome)")
    case .success(let enabled?):
      guard enabled else {
        return refused(
          "telemetry is off ([telemetry] enabled = false); set telemetry.enabled to true to "
            + "record agent usage")
      }
    }
    guard HookDecisionEvent.sessionID(options.session) != nil else {
      return refused("--session \(options.session) is not a session id")
    }
    if let task = options.task, HookDecisionEvent.sessionID(task) == nil {
      return refused("--task \(task) is not a task id of letters, digits, `_` and `-`")
    }
    if let buildRun = options.buildRun, !RunID.isValid(buildRun) {
      return refused("--build-run \(buildRun) is not a build run id")
    }

    if options.agentID != nil {
      if options.workflowTranscripts != nil {
        return refused(
          "--agent-id and --workflow-transcripts both name the agents --role tags; pass 1")
      }
      if options.role == nil {
        return refused("--agent-id needs --role: what that subagent worked as")
      }
    }

    let transcriptPath: String
    do {
      guard
        let record = try SessionRecordStore(worktreeRoot: root).record(sessionID: options.session)
      else {
        return refused("no session record for \(options.session)")
      }
      guard let path = record.transcriptPath else {
        return refused("the session record for \(options.session) names no transcript")
      }
      transcriptPath = path
    } catch {
      return refused("the session record for \(options.session) can't be read")
    }

    // With worker transcripts, --role and --task describe the workers, and the session running
    // them is the orchestrator; without, they describe the session itself. With --agent-id they
    // describe 1 subagent the session launched itself, and only that transcript is read: any
    // other subagent may belong to a workflow still running, which its own ingest tags.
    let sessionTags: (role: AgentRole?, task: String?) =
      options.workflowTranscripts == nil ? (options.role, options.task) : (.orchestrator, nil)
    var transcripts: [UsageTranscript] = []
    var toolTranscripts: [ToolTranscript] = []
    do throws(TranscriptReadError) {
      let reader = TranscriptReader()
      var files: [(file: TranscriptFile, role: AgentRole?, task: String?)] = []
      // Workers first: the first transcript to hold a message tags it, and a worker's file may
      // also sit under the session's own subagents.
      if let directory = options.workflowTranscripts {
        files += try reader.workflow(in: URL(filePath: directory, directoryHint: .isDirectory))
          .map { ($0, options.role, options.task) }
      }
      let session = try reader.session(at: URL(filePath: transcriptPath))
      if let agentID = options.agentID {
        guard
          let subagent = session.first(where: { $0.agent == .subagent && $0.agentID == agentID })
        else {
          return refused("--agent-id \(agentID) names no subagent transcript of this session")
        }
        files.append((subagent, options.role, options.task))
      } else {
        files += session.map { ($0, sessionTags.role, sessionTags.task) }
      }
      for (file, role, task) in files {
        do throws(TranscriptUsageError) {
          transcripts.append(
            UsageTranscript(
              agent: file.agent, agentID: file.agentID, role: role, task: task,
              messages: try TranscriptUsage.messages(in: file.data)))
          toolTranscripts.append(
            ToolTranscript(
              agent: file.agent, agentID: file.agentID, role: role, task: task,
              calls: try TranscriptTools.calls(in: file.data)))
        } catch {
          return refused("\(file.label), \(error)")
        }
      }
    } catch {
      return refused(error.description)
    }

    let read = EventStoreReader(files: LiveEventStoreFiles(root: root))
      .read(EventQuery(kinds: [.agentUsage, .agentTools]))
    let stored = UsageIngest.resolved(
      read.events.compactMap { stored -> AgentUsageEvent? in
        guard case .agentUsage(let usage) = stored.event.payload,
          usage.sessionID == options.session
        else { return nil }
        return usage
      })
    let damage = EventsDamage.lines(read.damage, command: "events ingest")
    let plan = UsageIngest.plan(
      sessionID: options.session, transcripts: transcripts, buildRun: options.buildRun,
      stored: Set(stored.map(\.messageID)),
      untagged: Set(stored.filter { $0.role == nil }.map(\.messageID)), prices: prices)
    let cwds = Set(toolTranscripts.flatMap { $0.calls.compactMap(\.cwd) })
    let topLevel = GitTopLevel()
    let tools = ToolIngest.plan(
      sessionID: options.session, transcripts: toolTranscripts, buildRun: options.buildRun,
      topLevels: Dictionary(
        uniqueKeysWithValues: cwds.compactMap { cwd in
          topLevel.of(cwd).map { (cwd, $0) }
        }),
      stored: Set(
        read.events.compactMap {
          if case .agentTools = $0.event.payload { $0.event.eventID } else { nil }
        }))
    let events = plan.events + tools.events
    if !events.isEmpty {
      do throws(HarnessEventWriteError) {
        try EventWriterFactory.make(root: root, enabled: true).append(contentsOf: events)
      } catch {
        return refused("agent.usage and agent.tools not written: \(error)", stderr: damage)
      }
    }
    let dropped = tools.events.reduce(0) { total, event in
      if case .agentTools(let window) = event.payload { total + window.droppedPaths } else { total }
    }
    var lines = [
      "events ingest: \(plan.messagesRead) messages read, "
        + "\(plan.events.count - plan.retagged) new, \(plan.retagged) retagged, "
        + "\(plan.alreadyStored) already stored",
      "events ingest: \(tools.callsRead) tool calls read, \(tools.events.count) windows new, "
        + "\(tools.alreadyStored) already stored, \(dropped) paths outside the repository dropped",
    ]
    for model in plan.unpriced {
      let why =
        switch model.reason {
        case .unknownModel: "not in the price table \(prices.version)"
        case .missingRates(let classes):
          "price table \(prices.version) has no \(classes.map(\.rawValue).joined(separator: ", ")) rate"
        }
      lines.append("no costUSD for \(model.model), \(model.messages) messages: \(why)")
    }
    return EventsCommandOutput(
      stdout: lines.joined(separator: "\n"), stderr: damage, status: 0)
  }
}

struct EventsIngestCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "ingest",
    abstract: "Store each assistant message's token counts and cost from a session's transcripts.",
    discussion:
      "Reads, offline, the transcript the session record names, its subagents' transcripts, and "
      + "with --workflow-transcripts every agent-*.jsonl in that directory. Only message ids, "
      + "model ids, usage counts and times are kept: no transcript text, prompt or tool input. "
      + "Tool calls are counted by tool per agent per 60 s window, with their time and the "
      + "repository-relative paths file tools named; any other path is dropped and counted. "
      + "A message or window already stored for the session is skipped, so ingesting again adds "
      + "nothing, except that a message stored with no role is retagged by an ingest that gives "
      + "it one. With --workflow-transcripts, --role and --task tag the workers and the session's "
      + "own messages are tagged orchestrator; without, they tag the session's. With "
      + "--agent-id, only that subagent of the session is read, and --role (required) and "
      + "--task tag it: the merge fixer the build skill launches itself. "
      + "Exit 0 stored; 2 when [telemetry] enabled = false, outside a project, for a bad flag "
      + "value, an unreadable record or transcript, a malformed usage line or a failed write.")

  @Option(help: "The Claude Code session id whose record names its transcript.")
  var session: String

  @Option(help: "A directory of a Workflow's agent-*.jsonl worker transcripts.")
  var workflowTranscripts: String?

  @Option(help: "What the tagged agents worked as.")
  var role: AgentRole?

  @Option(help: "The plan task id the agents worked on.")
  var task: String?

  @Option(name: .customLong("build-run"), help: "The build run id the usage belongs to.")
  var buildRun: String?

  @Option(
    name: .customLong("agent-id"),
    help: "The id of 1 subagent of the session, as the Agent tool printed it.")
  var agentID: String?

  func run() throws {
    try EventsCommandRunner.finish(
      EventsIngestRun.make(
        options: EventsIngestRun.Options(
          session: session, workflowTranscripts: workflowTranscripts, role: role, task: task,
          buildRun: buildRun, agentID: agentID),
        root: EventsCommandRunner.root))
  }
}

extension AgentRole: ExpressibleByArgument {}

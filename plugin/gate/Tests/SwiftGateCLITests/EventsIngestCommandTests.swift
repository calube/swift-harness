import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

@Suite("events ingest")
struct EventsIngestCommandTests {
  static let plainSession = "5812f394-1a00-4182-a6ec-fa7944ec92fb"
  static let subagentSession = "a9349a9c-0ea7-41a9-bd3a-8792745db8b1"
  static let buildRun = "20261001T040911Z-13708165"

  /// A captured envelope's `total_cost_usd` and its 1 model's `modelUsage` token counts.
  struct Envelope {
    let cost: Double
    let tokens: [String: Int]
  }

  static func envelope(_ session: String) throws -> Envelope {
    let url = Fixture.directory.appending(path: "Transcripts/\(session).envelope.json")
    let object = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let models = try #require(object["modelUsage"] as? [String: [String: Any]])
    let usage = try #require(models["claude-opus-5-5"])
    return Envelope(
      cost: try #require(object["total_cost_usd"] as? Double),
      tokens: [
        "input-tokens": try #require(usage["inputTokens"] as? Int),
        "output-tokens": try #require(usage["outputTokens"] as? Int),
        "cache-write-tokens": try #require(usage["cacheCreationInputTokens"] as? Int),
        "cache-read-tokens": try #require(usage["cacheReadInputTokens"] as? Int),
      ])
  }

  /// `metrics`' token counts, by the cost section's metric names.
  static func tokens(_ metrics: [String: EventSummaryMetric]?) -> [String: Int] {
    var tokens: [String: Int] = [:]
    for name in ["input-tokens", "output-tokens", "cache-write-tokens", "cache-read-tokens"] {
      tokens[name] = metrics?[name].map { Int($0.value) }
    }
    return tokens
  }

  /// A project and, outside it, a copy of the captured transcripts laid out as Claude Code
  /// keeps them, with a session record for each session naming its transcript.
  struct Scenario {
    let repo: ProbeRepository
    let transcripts: URL

    init(config: String? = ProbeRepository.config) throws {
      repo = try ProbeRepository(config: config)
      transcripts = TestTemporaryDirectory.root
        .appending(path: "swiftgate-transcripts-\(UUID().uuidString)", directoryHint: .isDirectory)
        .resolvingSymlinksInPath()
      try FileManager.default.copyItem(
        at: Fixture.directory.appending(path: "Transcripts", directoryHint: .isDirectory),
        to: transcripts)
      for session in [plainSession, subagentSession] {
        try SessionRecordStore(worktreeRoot: repo.root).write(
          try SessionRecord(
            sessionId: session, recordedAt: Date(timeIntervalSince1970: 1_790_000_000),
            pluginRoot: "/plugin", pluginVersion: "0.1.0",
            treeHash: String(repeating: "a", count: 64),
            transcriptPath: transcripts.appending(path: "\(session).jsonl").path))
      }
    }

    func remove() {
      repo.remove()
      TestTemporaryDirectory.remove(transcripts)
    }

    func ingest(
      _ session: String, workflow: String? = nil, role: AgentRole? = nil, task: String? = nil,
      buildRun: String? = nil, agentID: String? = nil, prices: ModelPriceTable = .current
    ) -> EventsCommandOutput {
      EventsIngestRun.make(
        options: EventsIngestRun.Options(
          session: session, workflowTranscripts: workflow, role: role, task: task,
          buildRun: buildRun, agentID: agentID),
        root: repo.root, prices: prices)
    }

    /// The build skill's call after a task completes.
    func buildIngest(_ session: String, workflow: String, task: String) -> EventsCommandOutput {
      ingest(
        session, workflow: workflow, role: .buildWorker, task: task,
        buildRun: EventsIngestCommandTests.buildRun)
    }

    /// The build skill's call after the merge fixer, an Agent-tool subagent of the session, returns.
    func fixerIngest(_ session: String, agentID: String, task: String) -> EventsCommandOutput {
      ingest(
        session, role: .buildWorker, task: task, buildRun: EventsIngestCommandTests.buildRun,
        agentID: agentID)
    }

    /// The ship skill's call before its summary.
    func shipIngest(_ session: String) -> EventsCommandOutput {
      ingest(session, role: .orchestrator, buildRun: EventsIngestCommandTests.buildRun)
    }

    /// The cost section's metrics by group, then by name, as `events summary --json` prints them.
    func costMetrics(buildRun: String? = nil) throws -> [[String]: [String: EventSummaryMetric]] {
      let output = EventsSummaryRun.make(
        files: LiveEventStoreFiles(root: repo.root), query: EventQuery(buildRunID: buildRun),
        json: true, now: Date(), sections: [CostSection()])
      #expect(output.status == 0, "\(output.stderr)")
      let report = try JSONDecoder().decode(EventSummaryReport.self, from: Data(output.stdout.utf8))
      let section = try #require(report.sections.first { $0.id == .cost })
      var metrics: [[String]: [String: EventSummaryMetric]] = [:]
      for metric in section.metrics {
        #expect(metrics[metric.group]?[metric.name] == nil, "\(metric.group) \(metric.name)")
        metrics[metric.group, default: [:]][metric.name] = metric
      }
      return metrics
    }

    var toolWindows: [AgentToolsEvent] {
      EventStoreReader(files: LiveEventStoreFiles(root: repo.root))
        .read(EventQuery(kinds: [.agentTools])).events.compactMap {
          if case .agentTools(let tools) = $0.event.payload { tools } else { nil }
        }
    }

    var usages: [AgentUsageEvent] {
      EventStoreReader(files: LiveEventStoreFiles(root: repo.root))
        .read(EventQuery(kinds: [.agentUsage])).events.compactMap {
          if case .agentUsage(let usage) = $0.event.payload { usage } else { nil }
        }
    }

    /// Every file of the event store, read as text.
    func storeText() throws -> String {
      let harness = repo.root.appending(path: ".harness/events", directoryHint: .isDirectory)
      let files = FileManager.default.enumerator(at: harness, includingPropertiesForKeys: nil)
      var text = ""
      while let url = files?.nextObject() as? URL {
        guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
          continue
        }
        text += String(decoding: try Data(contentsOf: url), as: UTF8.self) + "\n"
      }
      return text
    }
  }

  @Test(
    "ingest stores 1 event per message of the session and its subagents, and a second ingest adds none — catches a repeated ingest double counting"
  )
  func ingestIsIdempotent() throws {
    let scenario = try Scenario()
    defer { scenario.remove() }
    let first = scenario.ingest(Self.subagentSession)
    #expect(first.status == 0, "\(first.stderr)")
    #expect(first.stdout.contains("3 new"), "\(first.stdout)")
    #expect(scenario.usages.count == 3)
    #expect(scenario.usages.filter { $0.agent == .subagent }.count == 1)

    let second = scenario.ingest(Self.subagentSession)
    #expect(second.status == 0, "\(second.stderr)")
    #expect(second.stdout.contains("0 new"), "\(second.stdout)")
    #expect(second.stdout.contains("3 already stored"), "\(second.stdout)")
    #expect(scenario.usages.count == 3)
  }

  @Test(
    "--workflow-transcripts tags each agent file as a subagent with its id, --role, --task and --build-run, and the session's own messages as orchestrator with the build run and no task — catches a build's orchestrator cost left untagged"
  )
  func workflowTranscriptsAreSubagents() throws {
    let scenario = try Scenario()
    defer { scenario.remove() }
    let workflow = scenario.transcripts.appending(path: "\(Self.subagentSession)/subagents").path
    let output = scenario.buildIngest(Self.plainSession, workflow: workflow, task: "some-task")
    #expect(output.status == 0, "\(output.stderr)")
    let byAgent = Dictionary(grouping: scenario.usages, by: \.agent)
    let subagent = try #require(byAgent[.subagent]?.first)
    #expect(byAgent[.subagent]?.count == 1)
    #expect(subagent.agentID == "a705c5b0d3c2b4f5b")
    #expect(subagent.role == .buildWorker)
    #expect(subagent.task == "some-task")
    #expect(subagent.buildRun == Self.buildRun)
    #expect(subagent.sessionID == Self.plainSession)
    let main = try #require(byAgent[.main]?.first)
    #expect(byAgent[.main]?.count == 1)
    #expect(main.role == .orchestrator)
    #expect(main.task == nil)
    #expect(main.buildRun == Self.buildRun)
  }

  @Test(
    "2 build-style ingests then a ship-style one give each message's cost once, the session's under orchestrator and the worker's under build-worker and its first task, with the session's tokens equal to its envelope — catches orchestrator cost reported as no role"
  )
  func buildThenShipCountsEachMessageOnce() throws {
    let scenario = try Scenario()
    defer { scenario.remove() }
    let workflow = scenario.transcripts.appending(path: "\(Self.subagentSession)/subagents").path
    #expect(scenario.buildIngest(Self.plainSession, workflow: workflow, task: "first").status == 0)
    #expect(scenario.buildIngest(Self.plainSession, workflow: workflow, task: "second").status == 0)
    let ship = scenario.shipIngest(Self.plainSession)
    #expect(ship.status == 0, "\(ship.stderr)")
    #expect(ship.stdout.contains("0 new"), "\(ship.stdout)")

    let metrics = try scenario.costMetrics(buildRun: Self.buildRun)
    #expect(metrics[["total"]]?["messages"]?.value == 2)
    #expect(metrics[["role", "no role"]] == nil)
    #expect(metrics[["role", "orchestrator"]]?["messages"]?.value == 1)
    #expect(metrics[["role", "build-worker"]]?["messages"]?.value == 1)
    #expect(metrics[["task", "first"]]?["messages"]?.value == 1)
    #expect(metrics[["task", "second"]] == nil)
    let envelope = try Self.envelope(Self.plainSession)
    #expect(Self.tokens(metrics[["role", "orchestrator"]]) == envelope.tokens)
    let orchestrator = try #require(metrics[["role", "orchestrator"]]?["cost-usd"]?.value)
    #expect(abs(orchestrator - envelope.cost) <= 0.01 * envelope.cost, "\(orchestrator)")
    let worker = try #require(metrics[["role", "build-worker"]]?["cost-usd"]?.value)
    let total = try #require(metrics[["total"]]?["cost-usd"]?.value)
    #expect(abs(total - (orchestrator + worker)) < 1e-12, "\(total)")
  }

  @Test(
    "an untagged copy from an older ingest is tagged once by the next ingest that gives it a role, and the summary counts the message once, under its role — catches a message counted twice or left with no role"
  )
  func olderUntaggedCopyIsSupersededOnce() throws {
    let scenario = try Scenario()
    defer { scenario.remove() }
    let workflow = scenario.transcripts.appending(path: "\(Self.subagentSession)/subagents").path
    #expect(scenario.ingest(Self.plainSession).status == 0)
    #expect(scenario.usages.map(\.role) == [nil])

    let first = scenario.buildIngest(Self.plainSession, workflow: workflow, task: "first")
    #expect(first.status == 0, "\(first.stderr)")
    #expect(first.stdout.contains("1 retagged"), "\(first.stdout)")
    let second = scenario.buildIngest(Self.plainSession, workflow: workflow, task: "second")
    #expect(second.stdout.contains("0 new, 0 retagged, 2 already stored"), "\(second.stdout)")
    let ship = scenario.shipIngest(Self.plainSession)
    #expect(ship.stdout.contains("0 new, 0 retagged, 1 already stored"), "\(ship.stdout)")
    #expect(scenario.usages.count == 3)

    for buildRun in [nil, Self.buildRun] {
      let metrics = try scenario.costMetrics(buildRun: buildRun)
      #expect(metrics[["total"]]?["messages"]?.value == 2, "\(String(describing: buildRun))")
      #expect(metrics[["role", "no role"]] == nil, "\(String(describing: buildRun))")
      #expect(metrics[["role", "orchestrator"]]?["messages"]?.value == 1)
      #expect(metrics[["build-run", "no build run"]] == nil)
      #expect(
        Self.tokens(metrics[["role", "orchestrator"]])
          == (try Self.envelope(Self.plainSession)).tokens)
    }
  }

  @Test(
    "a worker transcript that is also under the session's own subagents keeps the worker's tags, and the session's totals equal its envelope — catches a worker's usage filed as the orchestrator's"
  )
  func workerTagsWinOverTheSession() throws {
    let scenario = try Scenario()
    defer { scenario.remove() }
    let workflow = scenario.transcripts.appending(path: "\(Self.subagentSession)/subagents").path
    #expect(
      scenario.buildIngest(Self.subagentSession, workflow: workflow, task: "first").status == 0)
    #expect(scenario.shipIngest(Self.subagentSession).status == 0)
    let metrics = try scenario.costMetrics(buildRun: Self.buildRun)
    #expect(metrics[["role", "orchestrator"]]?["messages"]?.value == 2)
    #expect(metrics[["role", "build-worker"]]?["messages"]?.value == 1)
    #expect(metrics[["task", "first"]]?["messages"]?.value == 1)
    let envelope = try Self.envelope(Self.subagentSession)
    #expect(Self.tokens(metrics[["total"]]) == envelope.tokens)
    let total = try #require(metrics[["total"]]?["cost-usd"]?.value)
    #expect(abs(total - envelope.cost) <= 0.01 * envelope.cost, "\(total)")
  }

  @Test(
    "no word of the transcripts' message content and neither transcript path reaches the store or the output — catches transcript text or a path stored"
  )
  func noTextOrPathIsStored() throws {
    let scenario = try Scenario()
    defer { scenario.remove() }
    let workflow = scenario.transcripts.appending(path: "\(Self.subagentSession)/subagents").path
    #expect(scenario.ingest(Self.subagentSession).status == 0)
    let output = scenario.ingest(Self.plainSession, workflow: workflow, role: .buildWorker)
    #expect(output.status == 0)
    let store = try scenario.storeText()
    #expect(!scenario.usages.isEmpty)
    // The subagent session's Agent call makes a tool window, which must hold no word either.
    #expect(!scenario.toolWindows.isEmpty)

    // An event's own keys and closed values, which a prompt may also use.
    var vocabulary: Set<String> = []
    for line in store.split(separator: "\n")
    where line.contains("\"agent.usage\"") || line.contains("\"agent.tools\"") {
      vocabulary.formUnion(Self.keys(in: try JSONSerialization.jsonObject(with: Data(line.utf8))))
    }
    vocabulary.formUnion(UsageAgent.allCases.map(\.rawValue))
    vocabulary.formUnion(AgentRole.allCases.map(\.rawValue))
    vocabulary.formUnion(
      [
        HarnessEventKind.agentUsage.rawValue, HarnessEventKind.agentTools.rawValue,
        HarnessRoute.ingest.rawValue,
      ].flatMap {
        $0.split(separator: ".").map(String.init)
      })
    vocabulary = Set(vocabulary.map { $0.lowercased() })
    var words: Set<String> = []
    for name in [
      "\(Self.plainSession).jsonl", "\(Self.subagentSession).jsonl",
      "\(Self.subagentSession)/subagents/agent-a705c5b0d3c2b4f5b.jsonl",
    ] {
      let data = try Data(contentsOf: scenario.transcripts.appending(path: name))
      for line in data.split(separator: UInt8(ascii: "\n")) {
        let object = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        let message = try #require(object["message"] as? [String: Any])
        for text in Self.strings(in: message["content"] as Any) {
          for word in text.split(whereSeparator: { !$0.isLetter }) where word.count >= 4 {
            words.insert(word.lowercased())
          }
        }
      }
    }
    words.subtract(vocabulary)
    #expect(words.contains("launching"))
    let storeWords = Set(
      store.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
    #expect(words.intersection(storeWords).isEmpty, "\(words.intersection(storeWords).sorted())")
    for text in [store, output.stdout, output.stderr] {
      #expect(!text.contains(scenario.transcripts.path))
      #expect(!text.contains("subagents/"))
      #expect(!text.contains(".jsonl\""))
    }
  }

  /// Every key in a JSON object, at any depth.
  static func keys(in value: Any) -> Set<String> {
    if let array = value as? [Any] { return array.reduce(into: []) { $0.formUnion(keys(in: $1)) } }
    guard let object = value as? [String: Any] else { return [] }
    return object.reduce(into: Set(object.keys)) { $0.formUnion(keys(in: $1.value)) }
  }

  /// Every string value in a JSON object, at any depth; keys are the transcript's structure.
  static func strings(in value: Any) -> [String] {
    if let text = value as? String { return [text] }
    if let array = value as? [Any] { return array.flatMap { strings(in: $0) } }
    if let object = value as? [String: Any] { return object.values.flatMap { strings(in: $0) } }
    return []
  }

  @Test(
    "a model the table can't price is named in the output and stored with no costUSD — catches a 0 cost"
  )
  func unpricedModelIsNamed() throws {
    let scenario = try Scenario()
    defer { scenario.remove() }
    let output = scenario.ingest(
      Self.plainSession,
      prices: ModelPriceTable(version: "empty", source: "test", usdPerMillion: [:]))
    #expect(output.status == 0)
    #expect(output.stdout.contains("claude-opus-5-5"), "\(output.stdout)")
    #expect(output.stdout.contains("not in the price table"), "\(output.stdout)")
    #expect(scenario.usages.map(\.costUSD) == [nil])
    #expect(scenario.usages.map(\.priceTable) == ["empty"])
  }

  @Test(
    "with [telemetry] enabled = false ingest refuses naming telemetry.enabled and writes nothing — catches an opt-out that still records"
  )
  func disabledTelemetryRefuses() throws {
    let scenario = try Scenario(config: ProbeRepository.config + "\n[telemetry]\nenabled = false\n")
    defer { scenario.remove() }
    let output = scenario.ingest(Self.plainSession)
    #expect(output.status == 2)
    #expect(output.stderr.contains("telemetry.enabled"), "\(output.stderr)")
    #expect(
      !FileManager.default.fileExists(
        atPath: scenario.repo.root.appending(path: ".harness/events").path))
  }

  @Test(
    "a malformed usage line exits 2 naming the file and line number, not the text, and stores nothing — catches a bad line read as 0 tokens"
  )
  func malformedLineRefuses() throws {
    let scenario = try Scenario()
    defer { scenario.remove() }
    let url = scenario.transcripts.appending(path: "\(Self.subagentSession).jsonl")
    let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
    try Data(
      text.replacingOccurrences(of: "\"cache_read_input_tokens\":19717,", with: "").utf8
    ).write(to: url)
    let output = scenario.ingest(Self.subagentSession)
    #expect(output.status == 2)
    #expect(output.stderr.contains("line 5"), "\(output.stderr)")
    #expect(!output.stderr.contains("msg_"))
    #expect(!output.stderr.contains(scenario.transcripts.path))
    #expect(scenario.usages.isEmpty)
  }

  @Test(
    "a session with no record, or a bad --task, exits 2 naming it — catches an ingest that silently reads nothing"
  )
  func missingSessionRefuses() throws {
    let scenario = try Scenario()
    defer { scenario.remove() }
    let missing = scenario.ingest("no-such-session")
    #expect(missing.status == 2)
    #expect(missing.stderr.contains("no-such-session"), "\(missing.stderr)")
    let badTask = scenario.ingest(Self.plainSession, task: "a task/with a path")
    #expect(badTask.status == 2)
    #expect(badTask.stderr.contains("--task"), "\(badTask.stderr)")
    #expect(scenario.usages.isEmpty)
  }

  @Test(
    "ingest writes the tool session's windows beside its usage, with repo-relative files only, and a second ingest adds none — catches tool windows not written or doubled"
  )
  func toolWindowsAreIngested() throws {
    let scenario = try Scenario()
    defer { scenario.remove() }
    let session = "39933227-0a3a-4a70-b63e-3cd768834ff9"
    let root = scenario.repo.root.path(percentEncoded: false).trimmingCharacters(
      in: CharacterSet(charactersIn: "/"))
    try FileManager.default.createDirectory(
      at: scenario.repo.root.appending(path: ".git"), withIntermediateDirectories: true)
    let files = [
      "\(session).jsonl", "\(session)/subagents/agent-a4ad125449ad0c978.jsonl",
    ]
    for file in files {
      let url = scenario.transcripts.appending(path: file)
      let text = try String(contentsOf: url, encoding: .utf8)
      try Data(text.replacingOccurrences(of: "/REPO", with: "/\(root)").utf8).write(to: url)
    }
    try SessionRecordStore(worktreeRoot: scenario.repo.root).write(
      try SessionRecord(
        sessionId: session, recordedAt: Date(timeIntervalSince1970: 1_790_000_000),
        pluginRoot: "/plugin", pluginVersion: "0.1.0",
        treeHash: String(repeating: "a", count: 64),
        transcriptPath: scenario.transcripts.appending(path: "\(session).jsonl").path))

    let first = scenario.ingest(session, role: .buildWorker, task: "t", buildRun: Self.buildRun)
    #expect(first.status == 0, "\(first.stderr)")
    #expect(first.stdout.contains("8 tool calls read, 2 windows new"), "\(first.stdout)")
    let windows = scenario.toolWindows
    #expect(windows.count == 2)
    let main = try #require(windows.first { $0.agent == .main })
    #expect(main.files == ["Sources/Greeting.swift", "Sources/Farewell.swift"])
    #expect(main.droppedPaths == 1)
    #expect(main.task == "t" && main.role == .buildWorker && main.buildRun == Self.buildRun)
    #expect(windows.first { $0.agent == .subagent }?.agentID == "a4ad125449ad0c978")
    #expect(!(try scenario.storeText()).contains(root))

    let second = scenario.ingest(session, role: .buildWorker, task: "t", buildRun: Self.buildRun)
    #expect(second.status == 0, "\(second.stderr)")
    #expect(second.stdout.contains("0 windows new, 2 already stored"), "\(second.stdout)")
    #expect(scenario.toolWindows.count == 2)
  }

  @Test(
    "--agent-id stores only that subagent's messages, tagged with --role, --task and --build-run, and a later session ingest keeps them its own and files the rest as orchestrator — catches a merge fixer's usage filed as the orchestrator's"
  )
  func agentIDTagsOneSubagent() throws {
    let scenario = try Scenario()
    defer { scenario.remove() }
    let fixer = scenario.fixerIngest(
      Self.subagentSession, agentID: "a705c5b0d3c2b4f5b", task: "fix-task")
    #expect(fixer.status == 0, "\(fixer.stderr)")
    let stored = scenario.usages
    #expect(stored.count == 1)
    let usage = try #require(stored.first)
    #expect(usage.agent == .subagent)
    #expect(usage.agentID == "a705c5b0d3c2b4f5b")
    #expect(usage.role == .buildWorker)
    #expect(usage.task == "fix-task")
    #expect(usage.buildRun == Self.buildRun)
    #expect(scenario.toolWindows.allSatisfy { $0.agent == .subagent && $0.task == "fix-task" })

    #expect(scenario.shipIngest(Self.subagentSession).status == 0)
    let metrics = try scenario.costMetrics(buildRun: Self.buildRun)
    #expect(metrics[["role", "build-worker"]]?["messages"]?.value == 1)
    #expect(metrics[["task", "fix-task"]]?["messages"]?.value == 1)
    #expect(metrics[["role", "orchestrator"]]?["messages"]?.value == 2)
  }

  @Test(
    "--agent-id naming no subagent of the session, holding a path, beside --workflow-transcripts or without --role exits 2 naming the flag and stores nothing — catches a fixer ingest that silently tags nothing or the wrong agents",
    arguments: [
      ("no-such-agent", AgentRole.buildWorker, false, "no-such-agent"),
      ("../a705c5b0d3c2b4f5b", AgentRole.buildWorker, false, "--agent-id"),
      ("a705c5b0d3c2b4f5b", AgentRole.buildWorker, true, "--workflow-transcripts"),
      ("a705c5b0d3c2b4f5b", nil, false, "--role"),
    ] as [(String, AgentRole?, Bool, String)])
  func agentIDRefusals(_ agentID: String, role: AgentRole?, workflow: Bool, named: String) throws {
    let scenario = try Scenario()
    defer { scenario.remove() }
    let output = scenario.ingest(
      Self.subagentSession,
      workflow: workflow
        ? scenario.transcripts.appending(path: "\(Self.subagentSession)/subagents").path : nil,
      role: role, task: "fix-task", buildRun: Self.buildRun, agentID: agentID)
    #expect(output.status == 2, "\(output.stdout)")
    #expect(output.stderr.contains(named), "\(output.stderr)")
    #expect(!output.stderr.contains(scenario.transcripts.path))
    #expect(scenario.usages.isEmpty)
    #expect(scenario.toolWindows.isEmpty)
  }
}

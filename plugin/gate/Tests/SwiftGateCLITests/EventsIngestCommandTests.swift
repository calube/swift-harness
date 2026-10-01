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

  /// A project and, outside it, a copy of the captured transcripts laid out as Claude Code
  /// keeps them, with a session record for each session naming its transcript.
  struct Scenario {
    let repo: ProbeRepository
    let transcripts: URL

    init(config: String? = ProbeRepository.config) throws {
      repo = try ProbeRepository(config: config)
      transcripts = FileManager.default.temporaryDirectory
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
      try? FileManager.default.removeItem(at: transcripts)
    }

    func ingest(
      _ session: String, workflow: String? = nil, role: AgentRole? = nil, task: String? = nil,
      prices: ModelPriceTable = .current
    ) -> EventsCommandOutput {
      EventsIngestRun.make(
        options: EventsIngestRun.Options(
          session: session, workflowTranscripts: workflow, role: role, task: task, buildRun: nil),
        root: repo.root, prices: prices)
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
    "--workflow-transcripts reads each agent file as agent: subagent with its id and the --role and --task, leaving the session's own lines untagged — catches a worker's usage filed as the orchestrator's"
  )
  func workflowTranscriptsAreSubagents() throws {
    let scenario = try Scenario()
    defer { scenario.remove() }
    let workflow = scenario.transcripts.appending(path: "\(Self.subagentSession)/subagents").path
    let output = scenario.ingest(
      Self.plainSession, workflow: workflow, role: .buildWorker, task: "some-task")
    #expect(output.status == 0, "\(output.stderr)")
    let byAgent = Dictionary(grouping: scenario.usages, by: \.agent)
    let subagent = try #require(byAgent[.subagent]?.first)
    #expect(byAgent[.subagent]?.count == 1)
    #expect(subagent.agentID == "a705c5b0d3c2b4f5b")
    #expect(subagent.role == .buildWorker)
    #expect(subagent.task == "some-task")
    #expect(subagent.sessionID == Self.plainSession)
    let main = try #require(byAgent[.main]?.first)
    #expect(byAgent[.main]?.count == 1)
    #expect(main.role == nil)
    #expect(main.task == nil)
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

    // An event's own keys and closed values, which a prompt may also use.
    var vocabulary: Set<String> = []
    for line in store.split(separator: "\n") where line.contains("\"agent.usage\"") {
      vocabulary.formUnion(Self.keys(in: try JSONSerialization.jsonObject(with: Data(line.utf8))))
    }
    vocabulary.formUnion(UsageAgent.allCases.map(\.rawValue))
    vocabulary.formUnion(AgentRole.allCases.map(\.rawValue))
    vocabulary.formUnion(
      [HarnessEventKind.agentUsage.rawValue, HarnessRoute.ingest.rawValue].flatMap {
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
}

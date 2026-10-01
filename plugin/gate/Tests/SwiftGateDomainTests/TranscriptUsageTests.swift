import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("transcript usage and its price")
struct TranscriptUsageTests {
  static let plainSession = "5812f394-1a00-4182-a6ec-fa7944ec92fb"
  static let subagentSession = "a9349a9c-0ea7-41a9-bd3a-8792745db8b1"
  static let subagentFile = "\(subagentSession)/subagents/agent-a705c5b0d3c2b4f5b.jsonl"

  static func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: Fixture.directory.appending(path: "Transcripts/\(name)"))
  }

  /// The envelope's `total_cost_usd` and its 1 model's `modelUsage` token counts.
  struct Envelope {
    let cost: Double
    let input: Int
    let output: Int
    let cacheCreation: Int
    let cacheRead: Int
  }

  static func envelope(_ session: String) throws -> Envelope {
    let object = try #require(
      try JSONSerialization.jsonObject(with: fixture("\(session).envelope.json")) as? [String: Any])
    let models = try #require(object["modelUsage"] as? [String: [String: Any]])
    let usage = try #require(models["claude-opus-5-5"])
    return Envelope(
      cost: try #require(object["total_cost_usd"] as? Double),
      input: try #require(usage["inputTokens"] as? Int),
      output: try #require(usage["outputTokens"] as? Int),
      cacheCreation: try #require(usage["cacheCreationInputTokens"] as? Int),
      cacheRead: try #require(usage["cacheReadInputTokens"] as? Int))
  }

  /// The session's transcript and, for the subagent session, its subagent's.
  static func transcripts(_ session: String) throws -> [UsageTranscript] {
    var transcripts = [
      UsageTranscript(
        agent: .main, agentID: nil, role: nil, task: nil,
        messages: try TranscriptUsage.messages(in: fixture("\(session).jsonl")))
    ]
    if session == subagentSession {
      transcripts.append(
        UsageTranscript(
          agent: .subagent, agentID: "a705c5b0d3c2b4f5b", role: nil, task: nil,
          messages: try TranscriptUsage.messages(in: fixture(subagentFile))))
    }
    return transcripts
  }

  static func usages(_ plan: UsageIngestPlan) -> [AgentUsageEvent] {
    plan.events.compactMap {
      if case .agentUsage(let usage) = $0.payload { usage } else { nil }
    }
  }

  static func plan(
    _ session: String, stored: Set<String> = [], prices: ModelPriceTable = .current
  ) throws -> UsageIngestPlan {
    UsageIngest.plan(
      sessionID: session, transcripts: try transcripts(session), buildRun: nil, stored: stored,
      prices: prices)
  }

  /// Every line of a fixture, each without its newline.
  static func lines(_ name: String) throws -> [String] {
    String(decoding: try fixture(name), as: UTF8.self).split(separator: "\n").map(String.init)
  }

  @Test(
    "the captured transcripts' token sums, deduplicated by message id, equal each envelope's modelUsage — catches a per-block double count"
  )
  func tokenSumsMatchTheEnvelope() throws {
    for session in [Self.plainSession, Self.subagentSession] {
      let usages = Self.usages(try Self.plan(session))
      let envelope = try Self.envelope(session)
      #expect(usages.reduce(0) { $0 + $1.inputTokens } == envelope.input, "\(session)")
      #expect(usages.reduce(0) { $0 + $1.outputTokens } == envelope.output, "\(session)")
      #expect(
        usages.reduce(0) { $0 + $1.cacheCreationTokens } == envelope.cacheCreation, "\(session)")
      #expect(usages.reduce(0) { $0 + $1.cacheReadTokens } == envelope.cacheRead, "\(session)")
      #expect(Set(usages.map(\.messageID)).count == usages.count)
    }
    let messages = try TranscriptUsage.messages(in: Self.fixture("\(Self.subagentSession).jsonl"))
    #expect(
      messages.map(\.messageID) == ["msg_011CfacdkUUkwTmYaDR9wf9N", "msg_011CfacfJRdf1aMSi6aLNBBE"])
    #expect(messages.first?.time == (try Date("2026-10-01T01:02:33.145Z", strategy: .iso8601)))
  }

  /// The envelope's cost left after every rate the table confirms, per output token.
  static func outputRemainder(_ session: String) throws -> Double {
    let envelope = try Self.envelope(session)
    let rates = try #require(ModelPriceTable.current.usdPerMillion["claude-opus-5-5"])
    func rate(_ key: TokenPriceClass) throws -> Double {
      NSDecimalNumber(decimal: try #require(rates[key])).doubleValue / 1_000_000
    }
    let confirmed =
      Double(envelope.input) * (try rate(.input))
      + Double(envelope.cacheCreation) * (try rate(.cacheWrite5m))
      + Double(envelope.cacheRead) * (try rate(.cacheRead))
    return (envelope.cost - confirmed) / Double(envelope.output)
  }

  @Test(
    "the table's confirmed rates leave the same cost per output token in both envelopes, and a table completed with it prices the other session within 1% of its total_cost_usd — catches a wrong price key or a double-counted message"
  )
  func confirmedRatesExplainTheEnvelopes() throws {
    let plain = try Self.outputRemainder(Self.plainSession)
    let subagent = try Self.outputRemainder(Self.subagentSession)
    #expect(plain > 0)
    #expect(abs(plain - subagent) <= 0.01 * plain, "\(plain) vs \(subagent)")

    var rates = try #require(ModelPriceTable.current.usdPerMillion["claude-opus-5-5"])
    rates[.output] = Decimal(plain * 1_000_000)
    let completed = ModelPriceTable(
      version: "test", source: "test", usdPerMillion: ["claude-opus-5-5": rates])
    let usages = Self.usages(try Self.plan(Self.subagentSession, prices: completed))
    let costs = usages.compactMap(\.costUSD)
    #expect(costs.count == usages.count)
    let envelope = try Self.envelope(Self.subagentSession)
    let total = costs.reduce(0, +)
    #expect(abs(total - envelope.cost) <= 0.01 * envelope.cost, "\(total) vs \(envelope.cost)")
  }

  @Test(
    "a rate the envelopes don't confirm leaves costUSD absent and names the model and the missing rate, while priceTable still names the table — catches unpriced usage stored as 0"
  )
  func unconfirmedRateLeavesCostAbsent() throws {
    let plan = try Self.plan(Self.subagentSession)
    let usages = Self.usages(plan)
    #expect(usages.count == 3)
    #expect(usages.allSatisfy { $0.costUSD == nil })
    #expect(usages.allSatisfy { $0.priceTable == ModelPriceTable.current.version })
    #expect(!ModelPriceTable.current.version.isEmpty)
    #expect(
      plan.unpriced == [
        UnpricedModel(model: "claude-opus-5-5", messages: 3, reason: .missingRates([.output]))
      ])
  }

  @Test(
    "a model missing from the table gives no costUSD and names the model — catches a 0 cost for an unknown model"
  )
  func unknownModelIsNamed() throws {
    let empty = ModelPriceTable(version: "empty", source: "test", usdPerMillion: [:])
    let plan = try Self.plan(Self.plainSession, prices: empty)
    #expect(Self.usages(plan).map(\.costUSD) == [nil])
    #expect(
      plan.unpriced == [UnpricedModel(model: "claude-opus-5-5", messages: 1, reason: .unknownModel)]
    )
    #expect(
      empty.price(
        model: "claude-opus-5-5",
        usage: TokenUsage(input: 0, output: 0, cacheCreation: 0, cacheCreation1h: 0, cacheRead: 0))
        == .unpriced(.unknownModel))
  }

  @Test(
    "a message whose every token has a rate is priced at the sum of each class's tokens times its rate, 1-hour writes at their own rate — catches cache writes priced as input"
  )
  func pricesEachClass() throws {
    let table = ModelPriceTable(
      version: "test", source: "test",
      usdPerMillion: [
        "m": [.input: 1, .output: 10, .cacheWrite5m: 100, .cacheWrite1h: 1000, .cacheRead: 10_000]
      ])
    let usage = TokenUsage(input: 1, output: 2, cacheCreation: 7, cacheCreation1h: 4, cacheRead: 5)
    guard case .priced(let usd) = table.price(model: "m", usage: usage) else {
      Issue.record("unpriced")
      return
    }
    #expect(abs(usd - 0.054_321) < 1e-12, "\(usd)")
    let noRead = TokenUsage(input: 1, output: 0, cacheCreation: 0, cacheCreation1h: 0, cacheRead: 0)
    let partial = ModelPriceTable(version: "t", source: "t", usdPerMillion: ["m": [.input: 1]])
    guard case .priced(let inputOnly) = partial.price(model: "m", usage: noRead) else {
      Issue.record("a message using only priced classes was unpriced")
      return
    }
    #expect(abs(inputOnly - 0.000_001) < 1e-15)
    #expect(
      partial.price(model: "m", usage: usage)
        == .unpriced(.missingRates([.output, .cacheWrite5m, .cacheWrite1h, .cacheRead])))
  }

  @Test(
    "messages whose ids the store already holds for the session are skipped and counted — catches a second ingest adding events"
  )
  func storedMessagesAreSkipped() throws {
    let first = try Self.plan(Self.subagentSession)
    let ids = Set(Self.usages(first).map(\.messageID))
    let again = try Self.plan(Self.subagentSession, stored: ids)
    #expect(again.events.isEmpty)
    #expect(again.alreadyStored == 3)
    #expect(again.messagesRead == 3)
    let partly = try Self.plan(Self.subagentSession, stored: ["msg_011CfacdkUUkwTmYaDR9wf9N"])
    #expect(
      Self.usages(partly).map(\.messageID).sorted()
        == ids.subtracting(["msg_011CfacdkUUkwTmYaDR9wf9N"]).sorted())
  }

  @Test(
    "each event carries its transcript's agent, id and tags, the build run, the ingest route and the message time — catches a subagent's usage filed as the main agent's"
  )
  func eventsCarryTheirTags() throws {
    let main = try TranscriptUsage.messages(in: Self.fixture("\(Self.subagentSession).jsonl"))
    let sub = try TranscriptUsage.messages(in: Self.fixture(Self.subagentFile))
    let plan = UsageIngest.plan(
      sessionID: Self.subagentSession,
      transcripts: [
        UsageTranscript(agent: .main, agentID: nil, role: .orchestrator, task: nil, messages: main),
        UsageTranscript(
          agent: .subagent, agentID: "a705c5b0d3c2b4f5b", role: .buildWorker, task: "some-task",
          messages: sub),
      ],
      buildRun: "20261001T010203Z-1234", stored: [], prices: .current)
    let byAgent = Dictionary(grouping: Self.usages(plan), by: \.agent)
    #expect(byAgent[.main]?.count == 2)
    #expect(byAgent[.main]?.allSatisfy { $0.role == .orchestrator && $0.agentID == nil } == true)
    let subagent = try #require(byAgent[.subagent]?.first)
    #expect(subagent.agentID == "a705c5b0d3c2b4f5b")
    #expect(subagent.role == .buildWorker)
    #expect(subagent.task == "some-task")
    #expect(subagent.messageID == "msg_011Cfaces5tXKZjeUcQiWmgi")
    #expect(Self.usages(plan).allSatisfy { $0.buildRun == "20261001T010203Z-1234" })
    for event in plan.events {
      #expect(event.source.route == .ingest)
      guard case .agentUsage(let usage) = event.payload else { continue }
      #expect(event.time == usage.messageTime)
      #expect(event.kind.stream == .usage)
    }
    #expect(Set(plan.events.map(\.eventID)).count == plan.events.count)
  }

  @Test(
    "a usage line missing a count fails naming its line number and none of its text — catches a malformed line read as 0 tokens or echoed into a message"
  )
  func malformedLineIsNamed() throws {
    var lines = try Self.lines("\(Self.subagentSession).jsonl")
    lines[2] = lines[2].replacingOccurrences(of: "\"output_tokens\":119,", with: "")
    #expect(throws: TranscriptUsageError.self) {
      try TranscriptUsage.messages(in: Data((lines.joined(separator: "\n") + "\n").utf8))
    }
    do {
      _ = try TranscriptUsage.messages(in: Data((lines.joined(separator: "\n") + "\n").utf8))
    } catch {
      #expect(error.line == 3)
      #expect(!error.description.contains("Agent"))
      #expect(!error.description.contains("msg_"))
      #expect(!error.description.contains("reply"))
    }
  }

  @Test(
    "2 lines of 1 message id with different usage fail naming the later line — catches a changed transcript format summed silently"
  )
  func conflictingUsageFails() throws {
    var lines = try Self.lines("\(Self.subagentSession).jsonl")
    lines[2] = lines[2].replacingOccurrences(
      of: "\"output_tokens\":119,", with: "\"output_tokens\":120,")
    do {
      _ = try TranscriptUsage.messages(in: Data((lines.joined(separator: "\n") + "\n").utf8))
      Issue.record("no error")
    } catch {
      #expect(error.line == 3)
    }
  }

  @Test(
    "a torn last line and a <synthetic> message are skipped, and every other line still counts — catches a live session's half-written line failing ingest"
  )
  func tornAndSyntheticLinesAreSkipped() throws {
    var lines = try Self.lines("\(Self.subagentSession).jsonl")
    lines[4] = lines[4].replacingOccurrences(
      of: "\"model\":\"claude-opus-5-5\"", with: "\"model\":\"<synthetic>\"")
    let torn = lines.joined(separator: "\n") + "\n" + String(lines[1].prefix(80))
    let messages = try TranscriptUsage.messages(in: Data(torn.utf8))
    #expect(messages.map(\.messageID) == ["msg_011CfacdkUUkwTmYaDR9wf9N"])

    let notTorn = lines.joined(separator: "\n") + "\n" + String(lines[1].prefix(80)) + "\n"
    #expect(throws: TranscriptUsageError.self) {
      try TranscriptUsage.messages(in: Data(notTorn.utf8))
    }
  }
}

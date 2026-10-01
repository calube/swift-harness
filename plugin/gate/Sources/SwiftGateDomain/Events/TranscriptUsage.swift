import Foundation

/// What an agent whose usage is ingested was working as.
public enum AgentRole: String, Sendable, Codable, CaseIterable {
  case orchestrator
  case design
  case plan
  case buildWorker = "build-worker"
  case review
  case qa
}

/// Whether a message came from a session's own transcript or from a subagent's.
public enum UsageAgent: String, Sendable, Codable, CaseIterable {
  case main
  case subagent
}

/// The token counts of 1 API message, as its transcript line states them.
public struct TokenUsage: Sendable, Equatable {
  public let input: Int
  public let output: Int
  /// Every cache write, 5-minute and 1-hour.
  public let cacheCreation: Int
  /// The 1-hour part of ``cacheCreation``; the rest are 5-minute writes.
  public let cacheCreation1h: Int
  public let cacheRead: Int

  public init(input: Int, output: Int, cacheCreation: Int, cacheCreation1h: Int, cacheRead: Int) {
    self.input = input
    self.output = output
    self.cacheCreation = cacheCreation
    self.cacheCreation1h = cacheCreation1h
    self.cacheRead = cacheRead
  }
}

/// 1 API message of a transcript: its ids, time and usage, and nothing it said.
public struct TranscriptMessage: Sendable, Equatable {
  public let messageID: String
  public let model: String
  public let time: Date
  public let usage: TokenUsage

  public init(messageID: String, model: String, time: Date, usage: TokenUsage) {
    self.messageID = messageID
    self.model = model
    self.time = time
    self.usage = usage
  }
}

/// Why a transcript line couldn't be read. It names the line, never the line's text.
public struct TranscriptUsageError: Error, Sendable, Equatable, CustomStringConvertible {
  /// 1-based.
  public let line: Int
  public let reason: String

  public init(line: Int, reason: String) {
    self.line = line
    self.reason = reason
  }

  public var description: String { "line \(line): \(reason)" }
}

/// Reads usage counts from a Claude Code transcript: `message.id`, `message.model`,
/// `message.usage` and `timestamp` of each assistant line, and no other key.
public enum TranscriptUsage {
  /// Each distinct message in `data`, in the order first seen.
  public static func messages(in data: Data) throws(TranscriptUsageError) -> [TranscriptMessage] {
    []
  }
}

/// `agent.usage`: 1 API message's token counts and cost. Ids, counts, a model id and closed
/// values only: no transcript text, prompt, tool input or path.
public struct AgentUsageEvent: Sendable, Equatable, Codable {
  public let sessionID: String
  public let agent: UsageAgent
  /// The subagent's id, from its transcript's file name; `nil` for the main agent.
  public let agentID: String?
  public let role: AgentRole?
  public let task: String?
  public let buildRun: String?
  public let model: String
  public let messageID: String
  public let messageTime: Date
  public let inputTokens: Int
  public let outputTokens: Int
  public let cacheCreationTokens: Int
  public let cacheReadTokens: Int
  /// `nil` when ``ModelPriceTable`` can't price every token the message used; never 0 for that.
  public let costUSD: Double?
  /// The ``ModelPriceTable/version`` consulted, priced or not.
  public let priceTable: String

  public init(
    sessionID: String, agent: UsageAgent, agentID: String?, role: AgentRole?, task: String?,
    buildRun: String?, model: String, messageID: String, messageTime: Date, inputTokens: Int,
    outputTokens: Int, cacheCreationTokens: Int, cacheReadTokens: Int, costUSD: Double?,
    priceTable: String
  ) {
    self.sessionID = sessionID
    self.agent = agent
    self.agentID = agentID
    self.role = role
    self.task = task
    self.buildRun = buildRun
    self.model = model
    self.messageID = messageID
    self.messageTime = messageTime
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.cacheCreationTokens = cacheCreationTokens
    self.cacheReadTokens = cacheReadTokens
    self.costUSD = costUSD
    self.priceTable = priceTable
  }
}

/// 1 transcript's messages and what they're tagged with.
public struct UsageTranscript: Sendable, Equatable {
  public let agent: UsageAgent
  public let agentID: String?
  public let role: AgentRole?
  public let task: String?
  public let messages: [TranscriptMessage]

  public init(
    agent: UsageAgent, agentID: String?, role: AgentRole?, task: String?,
    messages: [TranscriptMessage]
  ) {
    self.agent = agent
    self.agentID = agentID
    self.role = role
    self.task = task
    self.messages = messages
  }
}

/// A model whose messages were stored without `costUSD`, and why.
public struct UnpricedModel: Sendable, Equatable {
  public let model: String
  public let messages: Int
  public let reason: UnpricedReason

  public init(model: String, messages: Int, reason: UnpricedReason) {
    self.model = model
    self.messages = messages
    self.reason = reason
  }
}

/// What 1 ingest writes.
public struct UsageIngestPlan: Sendable, Equatable {
  public let events: [HarnessEvent]
  /// Distinct messages read, stored before or not.
  public let messagesRead: Int
  /// Messages skipped because the store already holds their id for the session.
  public let alreadyStored: Int
  public let unpriced: [UnpricedModel]

  public init(
    events: [HarnessEvent], messagesRead: Int, alreadyStored: Int, unpriced: [UnpricedModel]
  ) {
    self.events = events
    self.messagesRead = messagesRead
    self.alreadyStored = alreadyStored
    self.unpriced = unpriced
  }
}

/// From a session's transcripts to the `agent.usage` events not stored yet.
public enum UsageIngest {
  /// `stored` is every message id the store already holds for `sessionID`.
  public static func plan(
    sessionID: String, transcripts: [UsageTranscript], buildRun: String?, stored: Set<String>,
    prices: ModelPriceTable
  ) -> UsageIngestPlan {
    UsageIngestPlan(events: [], messagesRead: 0, alreadyStored: 0, unpriced: [])
  }
}

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
  /// The model id Claude Code gives a message it wrote itself, with no API call behind it.
  public static let syntheticModel = "<synthetic>"

  /// Each distinct message in `data`, in the order first seen. Claude Code writes 1 line per
  /// content block, each with the whole message's usage, so a repeated id counts once; a repeat
  /// whose usage differs fails, since summing either would be a guess. Lines other than assistant
  /// messages, and synthetic messages, are skipped. So is a last line with no newline that isn't
  /// JSON: the session may still be writing it, and the next ingest reads it whole.
  public static func messages(in data: Data) throws(TranscriptUsageError) -> [TranscriptMessage] {
    let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
    let endsWithNewline = data.last == UInt8(ascii: "\n")
    var messages: [TranscriptMessage] = []
    var seen: [String: TokenUsage] = [:]
    for (index, line) in lines.enumerated() where !line.isEmpty {
      let number = index + 1
      guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
      else {
        if index == lines.count - 1, !endsWithNewline { break }
        throw TranscriptUsageError(line: number, reason: "not a JSON object")
      }
      guard object["type"] as? String == "assistant" else { continue }
      guard let message = try assistantMessage(object, line: number) else { continue }
      if let earlier = seen[message.messageID] {
        guard earlier == message.usage else {
          throw TranscriptUsageError(
            line: number, reason: "repeats an earlier message id with different usage")
        }
        continue
      }
      seen[message.messageID] = message.usage
      messages.append(message)
    }
    return messages
  }

  private static func assistantMessage(_ object: [String: Any], line: Int)
    throws(TranscriptUsageError) -> TranscriptMessage?
  {
    func malformed(_ what: String) -> TranscriptUsageError {
      TranscriptUsageError(line: line, reason: "assistant line has \(what)")
    }
    guard let message = object["message"] as? [String: Any] else {
      throw malformed("no `message` object")
    }
    guard let model = message["model"] as? String else { throw malformed("no `message.model`") }
    if model == syntheticModel { return nil }
    guard isModelID(model) else { throw malformed("a `message.model` that isn't a model id") }
    guard let id = message["id"] as? String, isMessageID(id) else {
      throw malformed("no `message.id` of letters, digits, `_` and `-`")
    }
    guard let text = object["timestamp"] as? String,
      let time = try? Date(text, strategy: timeFormat)
    else { throw malformed("no ISO 8601 `timestamp`") }
    guard let usage = message["usage"] as? [String: Any] else {
      throw malformed("no `message.usage` object")
    }
    func count(_ value: Any?, _ key: String) throws(TranscriptUsageError) -> Int {
      // JSONSerialization reads `true` as an NSNumber too; only a whole, non-negative number counts.
      guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
        let whole = Int(exactly: number.doubleValue), whole >= 0
      else { throw malformed("no whole, non-negative `message.usage.\(key)`") }
      return whole
    }
    let cacheCreation = try count(
      usage["cache_creation_input_tokens"], "cache_creation_input_tokens")
    var oneHour = 0
    if let split = usage["cache_creation"] {
      guard let split = split as? [String: Any] else {
        throw malformed("a `message.usage.cache_creation` that isn't an object")
      }
      let key = "ephemeral_1h_input_tokens"
      oneHour = try count(split[key] ?? 0, "cache_creation.\(key)")
      guard oneHour <= cacheCreation else {
        throw malformed("more 1-hour cache writes than cache writes")
      }
    }
    return TranscriptMessage(
      messageID: id, model: model, time: time,
      usage: TokenUsage(
        input: try count(usage["input_tokens"], "input_tokens"),
        output: try count(usage["output_tokens"], "output_tokens"),
        cacheCreation: cacheCreation, cacheCreation1h: oneHour,
        cacheRead: try count(usage["cache_read_input_tokens"], "cache_read_input_tokens")))
  }

  private static let timeFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

  /// Letters, digits, `_` and `-`, at most 128 bytes.
  static func isMessageID(_ text: String) -> Bool {
    isIdentifier(text, extra: [UInt8(ascii: "_"), UInt8(ascii: "-")])
  }

  /// A model id as Claude Code and the providers spell it: letters, digits and `-._:@[]`.
  static func isModelID(_ text: String) -> Bool {
    isIdentifier(text, extra: Set("-._:@[]".utf8))
  }

  static func isIdentifier(_ text: String, extra: Set<UInt8>) -> Bool {
    (1...128).contains(text.utf8.count)
      && text.utf8.allSatisfy {
        (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0)
          || extra.contains($0)
      }
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
  /// Of ``events``, those that supersede a copy stored with no role.
  public let retagged: Int
  public let unpriced: [UnpricedModel]

  public init(
    events: [HarnessEvent], messagesRead: Int, alreadyStored: Int, retagged: Int = 0,
    unpriced: [UnpricedModel]
  ) {
    self.events = events
    self.messagesRead = messagesRead
    self.alreadyStored = alreadyStored
    self.retagged = retagged
    self.unpriced = unpriced
  }
}

/// From a session's transcripts to the `agent.usage` events not stored yet.
public enum UsageIngest {
  /// `stored` is every message id the store already holds for `sessionID`; `untagged` is those
  /// of them whose copy ``resolved(_:)`` keeps has no role. An untagged message read here with a
  /// role gets a second event that supersedes it, so an ingest from before the role was known
  /// doesn't leave its cost unattributed. A message is only ever retagged from no role.
  public static func plan(
    sessionID: String, transcripts: [UsageTranscript], buildRun: String?, stored: Set<String>,
    untagged: Set<String> = [], prices: ModelPriceTable
  ) -> UsageIngestPlan {
    var events: [HarnessEvent] = []
    var read: Set<String> = []
    var alreadyStored = 0
    var retagged = 0
    var unpriced: [String: [UnpricedReason: Int]] = [:]
    for transcript in transcripts {
      for message in transcript.messages where read.insert(message.messageID).inserted {
        let original = eventID(sessionID: sessionID, messageID: message.messageID)
        var id = original
        var supersedes: String?
        if stored.contains(message.messageID) {
          guard let role = transcript.role, untagged.contains(message.messageID) else {
            alreadyStored += 1
            continue
          }
          id = "\(original)-\(role.rawValue)"
          supersedes = original
          retagged += 1
        }
        var cost: Double?
        switch prices.price(model: message.model, usage: message.usage) {
        case .priced(let usd): cost = usd
        case .unpriced(let reason): unpriced[message.model, default: [:]][reason, default: 0] += 1
        }
        let usage = AgentUsageEvent(
          sessionID: sessionID, agent: transcript.agent, agentID: transcript.agentID,
          role: transcript.role, task: transcript.task, buildRun: buildRun, model: message.model,
          messageID: message.messageID, messageTime: message.time,
          inputTokens: message.usage.input, outputTokens: message.usage.output,
          cacheCreationTokens: message.usage.cacheCreation,
          cacheReadTokens: message.usage.cacheRead, costUSD: cost, priceTable: prices.version)
        events.append(
          HarnessEvent(
            eventID: id, parentID: supersedes, time: message.time,
            source: HarnessEventSource(route: .ingest),
            payload: .agentUsage(usage)))
      }
    }
    return UsageIngestPlan(
      events: events, messagesRead: read.count, alreadyStored: alreadyStored, retagged: retagged,
      unpriced: unpriced.keys.sorted().flatMap { model in
        (unpriced[model] ?? [:]).map { UnpricedModel(model: model, messages: $1, reason: $0) }
          .sorted { "\($0.reason)" < "\($1.reason)" }
      })
  }

  /// The same message of the same session always gets the same id, so a store imported from
  /// another worktree joins it rather than doubling it.
  public static func eventID(sessionID: String, messageID: String) -> String {
    "usage-\(sessionID)-\(messageID)"
  }

  /// 1 copy of each message of each session, in the order first seen: one with a role over one
  /// without, since a retagged message keeps its untagged copy beside the one superseding it.
  /// Between 2 copies with a role, the first role in ``AgentRole`` order, so the choice doesn't
  /// hang on which store was read first.
  public static func resolved(_ usages: [AgentUsageEvent]) -> [AgentUsageEvent] {
    struct Key: Hashable {
      let session: String
      let message: String
    }
    let order = Dictionary(uniqueKeysWithValues: AgentRole.allCases.enumerated().map { ($1, $0) })
    func rank(_ usage: AgentUsageEvent) -> Int {
      usage.role.flatMap { order[$0] } ?? AgentRole.allCases.count
    }
    var kept: [AgentUsageEvent] = []
    var index: [Key: Int] = [:]
    for usage in usages {
      let key = Key(session: usage.sessionID, message: usage.messageID)
      guard let at = index[key] else {
        index[key] = kept.count
        kept.append(usage)
        continue
      }
      if rank(usage) < rank(kept[at]) { kept[at] = usage }
    }
    return kept
  }
}

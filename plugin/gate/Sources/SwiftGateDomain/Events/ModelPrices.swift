import Foundation

/// A class of token a model prices on its own.
public enum TokenPriceClass: String, Sendable, Codable, CaseIterable {
  case input
  case output
  case cacheWrite5m = "cache-write-5m"
  case cacheWrite1h = "cache-write-1h"
  case cacheRead = "cache-read"
}

/// Why a message has no `costUSD`.
public enum UnpricedReason: Sendable, Equatable, Hashable {
  /// The table has no row for the model.
  case unknownModel
  /// The table has the model, but not a rate for each class the message used.
  case missingRates([TokenPriceClass])
}

/// What a message cost, or why the table can't say.
public enum UsagePrice: Sendable, Equatable {
  case priced(usd: Double)
  case unpriced(UnpricedReason)
}

/// US dollars per million tokens, by model id and token class, with where each rate came from.
public struct ModelPriceTable: Sendable, Equatable {
  /// Stored in each `agent.usage` as `priceTable`, so a later rate change can't rewrite an old
  /// total unnoticed.
  public let version: String
  public let source: String
  public let usdPerMillion: [String: [TokenPriceClass: Decimal]]

  public init(version: String, source: String, usdPerMillion: [String: [TokenPriceClass: Decimal]])
  {
    self.version = version
    self.source = source
    self.usdPerMillion = usdPerMillion
  }

  /// Anthropic's first-party list prices. Cache writes are 1.25 times input for 5 minutes and 2
  /// times for 1 hour. Haiku 4.5's cache-read rate is only given as "about 0.1 times input", so
  /// it's left out and a Haiku message that reads the cache is stored without a cost. The captured
  /// `claude -p` envelopes' `total_cost_usd` agree with every Opus 5.5 rate they exercise.
  public static let current = ModelPriceTable(
    version: "2026-10-01",
    source:
      "claude-api skill of Claude Code 2.1.285: its Current Models table (cached 2026-09-25) for "
      + "input, output and cache-read rates, and its prompt-caching reference for cache writes",
    usdPerMillion: [
      "claude-opus-5-5": [
        .input: 4, .output: 20, .cacheWrite5m: 5, .cacheWrite1h: 8, .cacheRead: Decimal(2) / 10,
      ],
      "claude-sonnet-5-5": [
        .input: 2, .output: 10, .cacheWrite5m: Decimal(25) / 10, .cacheWrite1h: 4,
        .cacheRead: Decimal(2) / 10,
      ],
      "claude-haiku-4-5": [
        .input: 1, .output: 5, .cacheWrite5m: Decimal(125) / 100, .cacheWrite1h: 2,
      ],
    ])

  /// The sum of each class's tokens times its rate, or why there is none. A class the message
  /// didn't use needs no rate.
  public func price(model: String, usage: TokenUsage) -> UsagePrice {
    guard let rates = usdPerMillion[model] else { return .unpriced(.unknownModel) }
    let tokens: [TokenPriceClass: Int] = [
      .input: usage.input, .output: usage.output,
      .cacheWrite5m: usage.cacheCreation - usage.cacheCreation1h,
      .cacheWrite1h: usage.cacheCreation1h, .cacheRead: usage.cacheRead,
    ]
    let used = TokenPriceClass.allCases.filter { (tokens[$0] ?? 0) > 0 }
    let missing = used.filter { rates[$0] == nil }
    guard missing.isEmpty else { return .unpriced(.missingRates(missing)) }
    let perMillion = used.reduce(Decimal(0)) { sum, key in
      sum + Decimal(tokens[key] ?? 0) * (rates[key] ?? 0)
    }
    return .priced(usd: NSDecimalNumber(decimal: perMillion / 1_000_000).doubleValue)
  }
}

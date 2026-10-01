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

  /// Only rates the captured `claude -p` envelopes confirm. Those envelopes solve, with no
  /// remainder, to these 3 rates; they don't pin the output rate or show a 1-hour cache write, so
  /// neither is here and a message using either is stored without a cost.
  public static let current = ModelPriceTable(
    version: "2026-09-30",
    source:
      "total_cost_usd of 3 claude -p envelopes from Claude Code 2.1.285, captured 2026-10-01; "
      + "see the Transcripts fixtures",
    usdPerMillion: [
      "claude-opus-5-5": [.input: 4, .cacheWrite5m: 5, .cacheRead: Decimal(2) / 10]
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

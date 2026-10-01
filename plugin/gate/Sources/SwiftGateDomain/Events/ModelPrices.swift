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

  public static let current = ModelPriceTable(version: "", source: "", usdPerMillion: [:])

  public func price(model: String, usage: TokenUsage) -> UsagePrice {
    .unpriced(.unknownModel)
  }
}

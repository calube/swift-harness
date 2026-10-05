import Foundation

/// An asset on the fixed watchlist, keyed by its CoinGecko id.
public struct Asset: Equatable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let symbol: String

  public init(id: String, name: String, symbol: String) {
    self.id = id
    self.name = name
    self.symbol = symbol
  }

  public static let bitcoin = Asset(id: "bitcoin", name: "Bitcoin", symbol: "BTC")
  public static let ethereum = Asset(id: "ethereum", name: "Ethereum", symbol: "ETH")
  public static let solana = Asset(id: "solana", name: "Solana", symbol: "SOL")

  public static let watchlist: [Asset] = [.bitcoin, .ethereum, .solana]
}

/// An asset's current USD price and its 24-hour change in percent.
public struct Quote: Equatable, Identifiable, Sendable {
  public let id: Asset.ID
  public var usd: Double
  public var usdChange24h: Double

  public init(id: Asset.ID, usd: Double, usdChange24h: Double) {
    self.id = id
    self.usd = usd
    self.usdChange24h = usdChange24h
  }

  public var isUp: Bool { usdChange24h >= 0 }

  /// `$64,000.00`
  public var formattedPrice: String {
    usd.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")))
  }

  /// `+2.50%` or `-1.20%`
  public var formattedChange: String {
    String(format: "%+.2f%%", locale: Locale(identifier: "en_US_POSIX"), usdChange24h)
  }
}

/// 1 point of a price history.
public struct PricePoint: Equatable, Sendable {
  public let date: Date
  public let price: Double

  public init(date: Date, price: Double) {
    self.date = date
    self.price = price
  }
}

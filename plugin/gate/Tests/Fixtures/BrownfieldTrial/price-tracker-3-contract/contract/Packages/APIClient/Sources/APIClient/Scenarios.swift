import Foundation
import Synchronization

extension APIClient {
  /// A fake client with fixed data for UI tests and simulator flows, picked by the app's
  /// `-harness-scenario <name>` launch argument. `nil` for an unknown name.
  ///
  /// - `success`: quotes and charts load; each later quotes call adds $100 to every price.
  /// - `load-failure`: the first quotes call fails offline, later ones succeed.
  /// - `detail-failure`: quotes load, every chart call fails offline.
  public static func scenario(_ name: String) -> APIClient? {
    let quoteCalls = Mutex(0)
    let quotes: @Sendable ([String]) async throws -> [Quote] = { ids in
      let call = quoteCalls.withLock { calls in
        calls += 1
        return calls
      }
      if name == "load-failure", call == 1 { throw APIError.offline }
      let bump = Double(call - 1) * 100
      return Self.scenarioQuotes(bump: bump).filter { ids.contains($0.id) }
    }
    let chart: @Sendable (String) async throws -> [PricePoint] = { id in
      if name == "detail-failure" { throw APIError.offline }
      return Self.scenarioChart(for: id)
    }
    switch name {
    case "success", "load-failure", "detail-failure":
      return APIClient(
        fetchPosts: { [] },
        fetchQuotes: quotes,
        fetchChart: chart
      )
    default:
      return nil
    }
  }

  static func scenarioQuotes(bump: Double) -> [Quote] {
    [
      Quote(id: "bitcoin", usd: 64_000 + bump, usdChange24h: 2.5),
      Quote(id: "ethereum", usd: 3_100.5 + bump, usdChange24h: -1.2),
      Quote(id: "solana", usd: 145.25 + bump, usdChange24h: 4.1),
    ]
  }

  static func scenarioChart(for id: String) -> [PricePoint] {
    let base = scenarioQuotes(bump: 0).first { $0.id == id }?.usd ?? 100
    let start = Date(timeIntervalSince1970: 1_759_000_000)
    return (0..<7).map { day in
      PricePoint(
        date: start.addingTimeInterval(Double(day) * 86_400),
        price: base * (1 + Double(day % 3 - 1) * 0.02)
      )
    }
  }
}

import APIClient
import AppCore
import ComposableArchitecture
import Foundation
import LogClient
import Testing

@MainActor
struct WatchlistFeatureTests {
  nonisolated static let quotes = [
    Quote(id: "bitcoin", usd: 64_000.12, change24h: 2.5),
    Quote(id: "ethereum", usd: 3_100.5, change24h: -1.25),
    Quote(id: "solana", usd: 145.3, change24h: 0),
  ]
  nonisolated static let t0 = Date(timeIntervalSince1970: 1_760_000_000)
  nonisolated static let byID = Dictionary(uniqueKeysWithValues: quotes.map { ($0.id, $0) })

  private func store(
    state: WatchlistFeature.State = .init(),
    _ configure: (inout DependencyValues) -> Void
  ) -> TestStore<WatchlistFeature.State, WatchlistFeature.Action> {
    TestStore(initialState: state) {
      WatchlistFeature()
    } withDependencies: {
      $0.date.now = Self.t0
      configure(&$0)
    }
  }

  @Test("first load shows a spinner then the prices — catches a spinner that never resolves")
  func firstLoad() async {
    let asked = LockIsolated<[[String]]>([])
    let store = store {
      $0.apiClient.fetchQuotes = { ids in
        asked.withValue { $0.append(ids) }
        return Self.quotes
      }
    }
    await store.send(.task) { $0.isLoading = true }
    await store.receive(\.quotesResponse.success) {
      $0.isLoading = false
      $0.lastUpdated = Self.t0
      $0.quotes = Self.byID
    }
    #expect(asked.value == [["bitcoin", "ethereum", "solana"]])
  }

  @Test("appearing again after a load does not refetch — catches a reload on every appearance")
  func taskOnlyOnce() async {
    let loaded = WatchlistFeature.State(
      quotes: ["bitcoin": Self.quotes[0]], lastUpdated: Self.t0)
    let store = store(state: loaded) { _ in }
    await store.send(.task)
  }

  @Test("pull to refresh replaces prices and the update time — catches a stale last-updated")
  func refresh() async {
    let later = Date(timeIntervalSince1970: 1_760_000_100)
    let old = Quote(id: "bitcoin", usd: 1, change24h: 1)
    let loaded = WatchlistFeature.State(quotes: ["bitcoin": old], lastUpdated: Self.t0)
    let store = store(state: loaded) {
      $0.date.now = later
      $0.apiClient.fetchQuotes = { _ in Self.quotes }
    }
    await store.send(.refreshPulled)
    await store.receive(\.quotesResponse.success) {
      $0.lastUpdated = later
      $0.quotes = Self.byID
    }
  }

  @Test("a failed load shows the error and logs it, retry recovers — catches a dead retry button")
  func failureThenRetry() async {
    let records = LockIsolated<[LogRecord]>([])
    let fail = LockIsolated(true)
    let store = store {
      $0.apiClient.fetchQuotes = { _ in
        if fail.value { throw APIError.offline }
        return Self.quotes
      }
      $0.logClient.isEnabled = { _, _ in true }
      $0.logClient.emit = { record in records.withValue { $0.append(record) } }
    }
    await store.send(.task) { $0.isLoading = true }
    await store.receive(\.quotesResponse.failure) {
      $0.isLoading = false
      $0.loadError = .offline
    }
    #expect(
      records.value == [
        LogRecord(
          level: .error, category: "Watchlist", message: "quotes request failed",
          attributes: [.public("error", "offline")])
      ])
    fail.setValue(false)
    await store.send(.retryButtonTapped) {
      $0.isLoading = true
      $0.loadError = nil
    }
    await store.receive(\.quotesResponse.success) {
      $0.isLoading = false
      $0.lastUpdated = Self.t0
      $0.quotes = Self.byID
    }
  }

  @Test("a failed refresh keeps prices and time — catches a refresh that wipes good data")
  func failedRefreshKeepsData() async {
    let loaded = WatchlistFeature.State(
      quotes: ["bitcoin": Self.quotes[0]], lastUpdated: Self.t0)
    let store = store(state: loaded) {
      $0.date.now = Date(timeIntervalSince1970: 1_760_000_500)
      $0.apiClient.fetchQuotes = { _ in throw APIError.badStatus(503) }
    }
    await store.send(.refreshPulled)
    await store.receive(\.quotesResponse.failure) { $0.loadError = .badStatus(503) }
  }

  @Test("tapping an asset presents its detail with the quote — catches a missing quote")
  func tapPresentsDetail() async {
    let loaded = WatchlistFeature.State(
      quotes: ["ethereum": Self.quotes[1]], lastUpdated: Self.t0)
    let store = store(state: loaded) { _ in }
    await store.send(.assetTapped("ethereum")) {
      $0.detail = AssetDetailFeature.State(asset: .ethereum, quote: Self.quotes[1])
    }
  }

  @Test("tapping an unknown asset presents nothing — catches a detail for a stranger id")
  func tapUnknownAsset() async {
    let store = store { _ in }
    await store.send(.assetTapped("dogecoin"))
  }

  @Test("prices read as USD — catches a missing grouping or cents")
  func priceText() {
    #expect(WatchlistFormat.priceText(64_000.12) == "$64,000.12")
    #expect(WatchlistFormat.priceText(145.3) == "$145.30")
  }

  @Test("changes carry a sign and zero counts as up — catches a lost minus or a red zero")
  func changeText() {
    #expect(WatchlistFormat.changeText(2.5) == "+2.50%")
    #expect(WatchlistFormat.changeText(-1.25) == "-1.25%")
    #expect(WatchlistFormat.changeText(0) == "+0.00%")
    #expect(WatchlistFormat.isUp(0))
    #expect(WatchlistFormat.isUp(2.5))
    #expect(!WatchlistFormat.isUp(-0.01))
  }
}

import APIClient
import AppCore
import ComposableArchitecture
import Foundation
import Testing

@MainActor
struct AppFeatureTests {
  @Test("watchlist actions reach the hosted watchlist — catches a root that isn't wired in")
  func hostsWatchlist() async {
    let quotes = [Quote(id: "bitcoin", usd: 5, change24h: 1)]
    let now = Date(timeIntervalSince1970: 1_760_000_000)
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.date.now = now
      $0.apiClient.fetchQuotes = { _ in quotes }
    }

    await store.send(.watchlist(.task)) { $0.watchlist.isLoading = true }
    await store.receive(\.watchlist.quotesResponse.success) {
      $0.watchlist.isLoading = false
      $0.watchlist.lastUpdated = now
      $0.watchlist.quotes = ["bitcoin": quotes[0]]
    }
  }
}

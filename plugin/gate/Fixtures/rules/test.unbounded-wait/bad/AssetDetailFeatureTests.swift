import APIClient
import AppCore
import ComposableArchitecture
import Foundation
import Testing

@MainActor
struct AssetDetailFeatureTests {
  nonisolated static let quote = Quote(assetID: "bitcoin", price: 60_000, change24h: 1.5)
  nonisolated static let points = [
    PricePoint(date: Date(timeIntervalSince1970: 1_700_000_000), price: 59_000),
    PricePoint(date: Date(timeIntervalSince1970: 1_700_086_400), price: 60_000),
  ]

  @Test("chart success shows the points — catches the chart staying in loading")
  func chartSuccess() async {
    let store = TestStore(initialState: AssetDetailFeature.State(asset: .bitcoin, quote: Self.quote)) {
      AssetDetailFeature()
    } withDependencies: {
      $0.apiClient.fetchChart = { _ in Self.points }
    }
    await store.send(.task) { $0.chart = .loading }
    await store.receive(\.chartResponse.success) { $0.chart = .loaded(Self.points) }
  }

  @Test("chart failure keeps the quote and retry recovers — catches the quote vanishing or retry doing nothing")
  func chartFailureThenRetry() async {
    let fail = LockIsolated(true)
    let store = TestStore(initialState: AssetDetailFeature.State(asset: .bitcoin, quote: Self.quote)) {
      AssetDetailFeature()
    } withDependencies: {
      $0.apiClient.fetchChart = { _ in
        if fail.value { throw APIError.offline }
        return Self.points
      }
    }
    await store.send(.task) { $0.chart = .loading }
    await store.receive(\.chartResponse.failure) { $0.chart = .failed(.offline) }
    #expect(store.state.quote == Self.quote)
    fail.setValue(false)
    await store.send(.retryChartButtonTapped) { $0.chart = .loading }
    await store.receive(\.chartResponse.success) { $0.chart = .loaded(Self.points) }
    #expect(store.state.quote == Self.quote)
  }

  @Test("dismissing the detail cancels the suspended chart request — catches a leaked chart effect")
  func dismissCancelsChart() async {
    let started = LockIsolated(false)
    let cancelled = LockIsolated(false)
    let store = TestStore(
      initialState: WatchlistFeature.State(
        quotes: ["bitcoin": Self.quote], status: .loaded)
    ) {
      WatchlistFeature()
    } withDependencies: {
      $0.apiClient.fetchChart = { _ in
        started.setValue(true)
        do {
          try await Task.sleep(for: .seconds(3600))
        } catch {
          cancelled.setValue(Task.isCancelled)
          throw error
        }
        return []
      }
    }
    await store.send(.assetTapped("bitcoin")) {
      $0.detail = AssetDetailFeature.State(asset: .bitcoin, quote: Self.quote)
    }
    await store.send(.detail(.presented(.task))) { $0.detail?.chart = .loading }
    while !started.value { await Task.yield() }
    await store.send(.detail(.dismiss)) { $0.detail = nil }
    while !cancelled.value { await Task.yield() }
    #expect(cancelled.value)
  }
}

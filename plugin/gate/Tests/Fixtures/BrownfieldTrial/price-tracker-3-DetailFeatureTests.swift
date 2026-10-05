import APIClient
import AppCore
import ComposableArchitecture
import Foundation
import Testing

@MainActor
struct DetailFeatureTests {
  nonisolated static let quote = Quote(id: "bitcoin", usd: 64_000, usdChange24h: 2.5)
  nonisolated static let points = [
    PricePoint(date: Date(timeIntervalSince1970: 0), price: 60_000),
    PricePoint(date: Date(timeIntervalSince1970: 86_400), price: 64_000),
  ]

  @Test("appearing loads the chart — catches a chart that never leaves loading")
  func taskLoadsChart() async {
    let store = TestStore(
      initialState: DetailFeature.State(asset: .bitcoin, quote: Self.quote)
    ) {
      DetailFeature()
    } withDependencies: {
      $0.apiClient.fetchChart = { id in
        #expect(id == "bitcoin")
        return Self.points
      }
    }

    await store.send(.task) { $0.chart = .loading }
    await store.receive(\.chartResponse.success) { $0.chart = .loaded(Self.points) }
  }

  @Test("a failed chart keeps the price — catches a chart error hiding the price")
  func failureKeepsPrice() async {
    let store = TestStore(
      initialState: DetailFeature.State(asset: .bitcoin, quote: Self.quote)
    ) {
      DetailFeature()
    } withDependencies: {
      $0.apiClient.fetchChart = { _ in throw APIError.offline }
    }

    await store.send(.task) { $0.chart = .loading }
    await store.receive(\.chartResponse.failure) { $0.chart = .failed(.offline) }
    #expect(store.state.quote == Self.quote)
  }

  @Test("an unexpected error type still ends loading — catches a spinner stuck on a non-API error")
  func unexpectedErrorEndsLoading() async {
    struct Unexpected: Error {}
    let store = TestStore(
      initialState: DetailFeature.State(asset: .bitcoin, quote: Self.quote)
    ) {
      DetailFeature()
    } withDependencies: {
      $0.apiClient.fetchChart = { _ in throw Unexpected() }
    }

    await store.send(.task) { $0.chart = .loading }
    await store.receive(\.chartResponse.failure) { $0.chart = .failed(.undecodable) }
  }

  @Test("retry after a failure reloads the chart — catches a retry button doing nothing")
  func retryReloads() async {
    let store = TestStore(
      initialState: DetailFeature.State(
        asset: .bitcoin, quote: Self.quote, chart: .failed(.badStatus(503)))
    ) {
      DetailFeature()
    } withDependencies: {
      $0.apiClient.fetchChart = { _ in Self.points }
    }

    await store.send(.retryChartButtonTapped) { $0.chart = .loading }
    await store.receive(\.chartResponse.success) { $0.chart = .loaded(Self.points) }
  }

  @Test("dismissing the detail cancels a running chart request — catches a leaked request")
  func dismissCancelsChart() async {
    let cancelled = LockIsolated(false)
    let store = TestStore(
      initialState: WatchlistFeature.State(
        detail: DetailFeature.State(asset: .bitcoin, quote: Self.quote))
    ) {
      WatchlistFeature()
    } withDependencies: {
      $0.apiClient.fetchChart = { _ in
        do {
          try await Task.sleep(for: .seconds(1_000))
        } catch {
          cancelled.setValue(true)
          throw error
        }
        return Self.points
      }
    }

    await store.send(\.detail.presented.task) { $0.detail?.chart = .loading }
    await store.send(\.detail.dismiss) { $0.detail = nil }
    await store.finish()
    #expect(cancelled.value)
  }
}

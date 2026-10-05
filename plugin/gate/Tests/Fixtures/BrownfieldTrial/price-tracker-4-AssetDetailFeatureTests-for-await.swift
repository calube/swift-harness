import APIClient
import AppCore
import ComposableArchitecture
import Foundation
import Testing

@MainActor
struct AssetDetailFeatureTests {
  nonisolated static let quote = Quote(id: "bitcoin", usd: 64_000, change24h: 1.5)
  nonisolated static let points = [
    PricePoint(date: Date(timeIntervalSince1970: 0), usd: 63_000),
    PricePoint(date: Date(timeIntervalSince1970: 86_400), usd: 64_000),
  ]

  private func makeStore(
    chart: @escaping @Sendable (Asset.ID) async throws -> [PricePoint]
  ) -> TestStoreOf<AssetDetailFeature> {
    TestStore(initialState: AssetDetailFeature.State(asset: .bitcoin, quote: Self.quote)) {
      AssetDetailFeature()
    } withDependencies: {
      $0.apiClient.fetchChart = chart
    }
  }

  @Test("appearing loads the 7-day chart — catches a chart that never leaves loading")
  func chartLoads() async {
    let store = makeStore { id in
      #expect(id == "bitcoin")
      return Self.points
    }

    await store.send(.task) { $0.chart = .loading }
    await store.receive(\.chartResponse.success) { $0.chart = .loaded(Self.points) }
  }

  @Test("a chart failure keeps the quote — catches an error that hides the price")
  func chartFailureKeepsQuote() async {
    let store = makeStore { _ in throw APIError.offline }

    await store.send(.task) { $0.chart = .loading }
    await store.receive(\.chartResponse.failure) { $0.chart = .failed(.offline) }
    #expect(store.state.quote == Self.quote)
  }

  @Test("retry reloads the chart after a failure — catches a retry button that does nothing")
  func retryReloads() async {
    let attempts = LockIsolated(0)
    let store = makeStore { _ in
      let attempt = attempts.withValue { value -> Int in
        value += 1
        return value
      }
      if attempt == 1 { throw APIError.badStatus(500) }
      return Self.points
    }

    await store.send(.task) { $0.chart = .loading }
    await store.receive(\.chartResponse.failure) { $0.chart = .failed(.badStatus(500)) }
    await store.send(.retryChartButtonTapped) { $0.chart = .loading }
    await store.receive(\.chartResponse.success) { $0.chart = .loaded(Self.points) }
    #expect(attempts.value == 2)
  }

  @Test("cancelling the task cancels a never-finishing chart request — catches a leaked request")
  func cancellationStopsRequest() async {
    let cancelled = LockIsolated(false)
    let started = AsyncStream<Void>.makeStream()
    let store = makeStore { _ in
      await withTaskCancellationHandler {
        started.continuation.yield()
        try? await Task.sleep(for: .seconds(3_600))
        return []
      } onCancel: {
        cancelled.setValue(true)
      }
    }

    let task = await store.send(.task) { $0.chart = .loading }
    for await _ in started.stream { break }
    await task.cancel()
    #expect(cancelled.value)
    #expect(store.state.chart == .loading)
  }
}

import APIClient
import ComposableArchitecture

/// 1 asset's current price and its 7-day chart, which loads and fails on its own.
@Reducer
public struct DetailFeature {
  @ObservableState
  public struct State: Equatable {
    public var asset: Asset
    public var quote: Quote?
    public var chart: ChartStatus

    public init(asset: Asset, quote: Quote?, chart: ChartStatus = .idle) {
      self.asset = asset
      self.quote = quote
      self.chart = chart
    }
  }

  public enum ChartStatus: Equatable, Sendable {
    case idle
    case loading
    case loaded([PricePoint])
    case failed(APIError)
  }

  public enum Action: Equatable {
    case task
    case retryChartButtonTapped
    case chartResponse(Result<[PricePoint], APIError>)
  }

  @Dependency(\.apiClient) var apiClient

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { _, _ in .none }
  }
}

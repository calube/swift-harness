import APIClient
import ComposableArchitecture
import Foundation
import LogClient

/// The fixed watchlist: each asset's price and 24-hour change, refreshable, presenting its detail.
@Reducer
public struct WatchlistFeature {
  @ObservableState
  public struct State: Equatable {
    public var assets: [Asset]
    public var quotes: [Asset.ID: Quote]
    public var status: Status
    public var lastUpdated: Date?
    @Presents public var detail: DetailFeature.State?

    public init(
      assets: [Asset] = Asset.watchlist,
      quotes: [Asset.ID: Quote] = [:],
      status: Status = .idle,
      lastUpdated: Date? = nil,
      detail: DetailFeature.State? = nil
    ) {
      self.assets = assets
      self.quotes = quotes
      self.status = status
      self.lastUpdated = lastUpdated
      self.detail = detail
    }
  }

  public enum Status: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(APIError)
  }

  public enum Action: Equatable {
    case task
    case refresh
    case retryButtonTapped
    case quotesResponse(Result<[Quote], APIError>)
    case assetTapped(Asset.ID)
    case detail(PresentationAction<DetailFeature.Action>)
  }

  @Dependency(\.apiClient) var apiClient
  @Dependency(\.date.now) var now
  @Dependency(\.logClient) var log

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { _, _ in .none }
      .ifLet(\.$detail, action: \.detail) { DetailFeature() }
  }
}

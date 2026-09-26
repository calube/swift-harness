import ComposableArchitecture
import FeedClient

@Reducer
public struct Feed {
  @ObservableState
  public struct State: Equatable {
    public var items: [String] = []
  }
  public enum Action {
    case refreshTapped
  }
  public var body: some ReducerOf<Self> {
    Reduce { _, _ in .none }
  }
}

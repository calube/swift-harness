import APIClient
import ComposableArchitecture
import LogClient

@Reducer
public struct CounterFeature {
  @ObservableState
  public struct State: Equatable {
    public var count: Int
    public var fact: String?
    public var isLoadingFact: Bool

    public init(count: Int = 0, fact: String? = nil, isLoadingFact: Bool = false) {
      self.count = count
      self.fact = fact
      self.isLoadingFact = isLoadingFact
    }
  }

  public enum Action: Equatable {
    case incrementButtonTapped
    case decrementButtonTapped
    case factButtonTapped
    case factResponse(String)
    case factFailed
  }

  @Dependency(\.apiClient) var apiClient
  @Dependency(\.logClient) var log

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .incrementButtonTapped:
        state.count += 1
        state.fact = nil
        return .none

      case .decrementButtonTapped:
        state.count -= 1
        state.fact = nil
        return .none

      case .factButtonTapped:
        state.isLoadingFact = true
        return .run { [count = state.count, apiClient, log] send in
          do {
            await send(.factResponse(try await apiClient.randomFact().text))
          } catch {
            log.log(.error, "fact request failed", category: "Counter", [.public("count", count)])
            await send(.factFailed)
          }
        }

      case .factResponse(let fact):
        state.isLoadingFact = false
        state.fact = fact
        return .none

      case .factFailed:
        state.isLoadingFact = false
        return .none
      }
    }
  }
}

func seededProbe() async throws {
  _ = Foundation.Date()
}

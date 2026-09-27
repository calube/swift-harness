import APIClient
import ComposableArchitecture
import LogClient

@Reducer
public struct AppFeature {
  @ObservableState
  public struct State: Equatable {
    public var status: Status

    public init(status: Status = .idle) {
      self.status = status
    }
  }

  public enum Status: Equatable, Sendable {
    case idle
    case loading
    case loaded(postCount: Int)
    case failed(APIError)
  }

  public enum Action: Equatable {
    case task
    case retryButtonTapped
    case postsResponse(Result<[Post], APIError>)
  }

  @Dependency(\.apiClient) var apiClient
  @Dependency(\.logClient) var log

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .task, .retryButtonTapped:
        state.status = .loading
        return .run { [apiClient] send in
          do {
            await send(.postsResponse(.success(try await apiClient.fetchPosts())))
          } catch let error as APIError {
            await send(.postsResponse(.failure(error)))
          } catch {
            await send(.postsResponse(.failure(.undecodable)))
          }
        }

      case .postsResponse(.success(let posts)):
        state.status = .loaded(postCount: posts.count)
        return .none

      case .postsResponse(.failure(let error)):
        state.status = .failed(error)
        log.log(.error, "posts request failed", category: "App", [.public("error", "\(error)")])
        return .none
      }
    }
  }
}

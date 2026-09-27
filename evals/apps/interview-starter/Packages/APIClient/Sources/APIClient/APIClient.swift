import Dependencies
import DependenciesMacros

public struct Post: Codable, Equatable, Identifiable, Sendable {
  public let id: Int
  public let userId: Int
  public var title: String
  public var body: String

  public init(id: Int, userId: Int, title: String, body: String) {
    self.id = id
    self.userId = userId
    self.title = title
    self.body = body
  }
}

public enum APIError: Error, Equatable, Sendable {
  /// No connection, or the request timed out before the server answered.
  case offline
  case badStatus(Int)
  case undecodable
}

@DependencyClient
public struct APIClient: Sendable {
  public var fetchPosts: @Sendable () async throws -> [Post]
}

extension APIClient: TestDependencyKey {
  public static let testValue = APIClient()
  public static let previewValue = APIClient(fetchPosts: {
    [
      Post(id: 1, userId: 1, title: "Preview post", body: "A post body shown in previews."),
      Post(id: 2, userId: 2, title: "Another preview post", body: "Second body."),
    ]
  })
}

extension DependencyValues {
  public var apiClient: APIClient {
    get { self[APIClient.self] }
    set { self[APIClient.self] = newValue }
  }
}

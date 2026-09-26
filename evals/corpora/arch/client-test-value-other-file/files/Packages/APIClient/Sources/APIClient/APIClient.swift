import Dependencies
import DependenciesMacros

public struct Fact: Sendable, Equatable {
  public var text: String

  public init(text: String) {
    self.text = text
  }
}

@DependencyClient
public struct APIClient: Sendable {
  public var randomFact: @Sendable () async throws -> Fact
}


extension DependencyValues {
  public var apiClient: APIClient {
    get { self[APIClient.self] }
    set { self[APIClient.self] = newValue }
  }
}

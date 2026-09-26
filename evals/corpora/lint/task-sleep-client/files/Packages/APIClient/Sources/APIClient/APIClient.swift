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

extension APIClient: TestDependencyKey {
  public static let testValue = APIClient()
  public static let previewValue = APIClient(randomFact: {
    Fact(text: "Cats sleep for around 13 to 14 hours a day.")
  })
}

extension DependencyValues {
  public var apiClient: APIClient {
    get { self[APIClient.self] }
    set { self[APIClient.self] = newValue }
  }
}

func seededProbe() async throws {
  try await Task.sleep(for: .seconds(1))
}

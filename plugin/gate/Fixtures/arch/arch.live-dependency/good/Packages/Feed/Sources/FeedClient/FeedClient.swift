import Dependencies
import DependenciesMacros

@DependencyClient
public struct FeedClient: Sendable {
  public var load: @Sendable () async throws -> [String]
}

extension FeedClient: TestDependencyKey {
  public static let testValue = FeedClient()
}

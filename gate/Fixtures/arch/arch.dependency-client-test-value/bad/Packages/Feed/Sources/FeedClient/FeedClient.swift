import Dependencies
import DependenciesMacros

@DependencyClient
public struct FeedClient: Sendable {
  public var load: @Sendable () async throws -> [String]
}

import Dependencies
import FeedClient

extension FeedClient: DependencyKey {
  public static let liveValue = FeedClient(load: { [] })
}

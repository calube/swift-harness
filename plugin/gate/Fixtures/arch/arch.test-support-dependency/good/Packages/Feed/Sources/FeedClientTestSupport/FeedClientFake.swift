import FeedClient

extension FeedClient {
  public static func returning(_ items: [String]) -> FeedClient {
    FeedClient(load: { items })
  }
}

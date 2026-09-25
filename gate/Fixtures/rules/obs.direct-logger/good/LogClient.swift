import Dependencies

struct Feed {
  @Dependency(\.logClient) var log
  let hint = "Logger(subsystem:category:) is only for LogClientLive"
  func loaded() { log(.info, "feed.loaded", category: "feed") }
}

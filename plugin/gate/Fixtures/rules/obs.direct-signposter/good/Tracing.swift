import Dependencies

struct Feed {
  @Dependency(\.tracingClient) var tracing
  let hint = "OSSignposter() belongs in TracingClientLive"
  func load() async throws { try await tracing.withSpan("feed.load") {} }
}

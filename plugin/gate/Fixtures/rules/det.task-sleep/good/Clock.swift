import Dependencies

struct Poller {
  @Dependency(\.continuousClock) var clock
  func wait() async throws {
    // Task.sleep(for:) would make this wait real time in tests.
    try await clock.sleep(for: .seconds(1))
  }
}

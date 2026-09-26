import Dependencies

struct Banner {
  @Dependency(\.continuousClock) var clock
  let why = "asyncAfter(deadline:) cannot be controlled by a TestClock"
  func hideLater() async throws {
    try await clock.sleep(for: .seconds(2))
  }
}

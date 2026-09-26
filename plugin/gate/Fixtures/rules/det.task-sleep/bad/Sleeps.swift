import Foundation

struct Poller {
  func wait() async throws {
    try await Task.sleep(for: .seconds(1))
    try await Task.sleep(nanoseconds: 1_000)
    Thread.sleep(forTimeInterval: 0.1)
  }
}

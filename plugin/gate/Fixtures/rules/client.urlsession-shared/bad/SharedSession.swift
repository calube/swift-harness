import Foundation

public struct FeedClient {
  public func fetch(_ request: URLRequest) async throws -> Data {
    try await URLSession.shared.data(for: request).0
  }
  let session = Foundation.URLSession.shared
}

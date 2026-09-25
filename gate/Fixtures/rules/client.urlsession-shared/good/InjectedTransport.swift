import Foundation

public struct FeedClient {
  public var fetch: @Sendable (URLRequest) async throws -> Data
  // URLSession.shared belongs in FeedClientLive.
  let note = "URLSession.shared"
  func ephemeral() -> URLSession { URLSession(configuration: .ephemeral) }
}

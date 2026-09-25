import Dependencies
import Foundation
import HTTPClient

extension HTTPClient {
  public static func live(session: URLSession) -> Self {
    Self(send: { request in
      let (data, response) = try await session.data(for: request)
      guard let httpResponse = response as? HTTPURLResponse else { throw HTTPError.nonHTTPResponse }
      return (data, httpResponse)
    })
  }
}

extension HTTPClient: DependencyKey {
  public static let liveValue = HTTPClient.live(session: .shared)
}

import APIClient
import Dependencies
import Foundation

extension APIClient {
  public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

  static let baseURL = URL(string: "https://jsonplaceholder.typicode.com")!

  public static func live(transport: @escaping Transport) -> Self {
    Self(fetchPosts: {
      var request = URLRequest(url: baseURL.appending(path: "posts"))
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      let data = try await send(request, over: transport)
      do {
        return try JSONDecoder().decode([Post].self, from: data)
      } catch {
        throw APIError.undecodable
      }
    })
  }

  private static func send(_ request: URLRequest, over transport: Transport) async throws -> Data {
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await transport(request)
    } catch let error as URLError where offlineCodes.contains(error.code) {
      throw APIError.offline
    }
    guard let status = (response as? HTTPURLResponse)?.statusCode else {
      throw APIError.undecodable
    }
    guard (200..<300).contains(status) else { throw APIError.badStatus(status) }
    return data
  }

  private static let offlineCodes: Set<URLError.Code> = [
    .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
    .cannotConnectToHost, .dataNotAllowed,
  ]
}

extension APIClient: DependencyKey {
  public static let liveValue = APIClient.live(transport: { request in
    try await URLSession.shared.data(for: request)
  })
}

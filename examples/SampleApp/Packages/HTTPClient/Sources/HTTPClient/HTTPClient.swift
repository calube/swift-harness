import Dependencies
import DependenciesMacros
import Foundation

public enum HTTPError: Error, Equatable {
  case unacceptableStatus(Int)
  case nonHTTPResponse
}

@DependencyClient
public struct HTTPClient: Sendable {
  public var send: @Sendable (_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension HTTPClient {
  public func data(for request: URLRequest) async throws -> Data {
    let (data, response) = try await send(request)
    guard (200..<300).contains(response.statusCode) else {
      throw HTTPError.unacceptableStatus(response.statusCode)
    }
    return data
  }
}

extension HTTPClient: TestDependencyKey {
  public static let testValue = HTTPClient()
}

extension DependencyValues {
  public var httpClient: HTTPClient {
    get { self[HTTPClient.self] }
    set { self[HTTPClient.self] = newValue }
  }
}

import Foundation

/// One HTTP request. Its description names the header fields but never their values, so a
/// request carrying a key can't leak it through string interpolation.
public struct HTTPRequest: Sendable, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public let method: String
  public let url: URL
  public let headers: [String: String]
  public let body: Data
  public let timeout: Duration

  public init(
    method: String, url: URL, headers: [String: String], body: Data, timeout: Duration
  ) {
    self.method = method
    self.url = url
    self.headers = headers
    self.body = body
    self.timeout = timeout
  }

  public var description: String { "" }

  public var debugDescription: String { description }
}

public struct HTTPResponse: Sendable, Equatable {
  public let status: Int
  /// Field names lowercased.
  public let headers: [String: String]
  public let body: Data

  public init(status: Int, headers: [String: String] = [:], body: Data) {
    self.status = status
    self.headers = headers
    self.body = body
  }
}

public enum HTTPTransportError: Error, Sendable, Equatable {
  case timedOut
  case unreachable(String)
}

public protocol HTTPTransport: Sendable {
  func send(_ request: HTTPRequest) async throws(HTTPTransportError) -> HTTPResponse
}

/// A monotonic clock for retry backoff and wall time, injectable so tests never sleep.
public protocol RetryClock: Sendable {
  /// Time since a fixed, arbitrary start.
  func now() -> Duration
  func sleep(for duration: Duration) async
}

public struct LiveRetryClock: RetryClock {
  public init() {}

  public func now() -> Duration { .zero }

  public func sleep(for duration: Duration) async {}
}

/// Sends over an ephemeral `URLSession`: no cookies, cache or credentials persist between calls.
public struct URLSessionTransport: HTTPTransport {
  private let configuration: @Sendable () -> URLSessionConfiguration

  /// `configuration` exists so tests can route requests to a `URLProtocol` stub.
  public init(
    configuration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }
  ) {
    self.configuration = configuration
  }

  public func send(_ request: HTTPRequest) async throws(HTTPTransportError) -> HTTPResponse {
    throw .timedOut
  }
}

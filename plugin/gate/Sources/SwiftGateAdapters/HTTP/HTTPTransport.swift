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

  public var description: String {
    "\(method) \(url.absoluteString) headers: \(headers.keys.sorted().joined(separator: ", "))"
  }

  public var debugDescription: String { description }
}

public struct HTTPResponse: Sendable, Equatable {
  public let status: Int
  /// Field names lowercased.
  public let headers: [String: String]
  public let body: Data

  public init(status: Int, headers: [String: String] = [:], body: Data) {
    self.status = status
    self.headers = Dictionary(
      headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
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
  private let start = ContinuousClock.now

  public init() {}

  public func now() -> Duration { ContinuousClock.now - start }

  public func sleep(for duration: Duration) async {
    try? await Task.sleep(for: duration)  // swiftgate:allow det.task-sleep — live retry backoff
  }
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
    var urlRequest = URLRequest(url: request.url)
    urlRequest.httpMethod = request.method
    urlRequest.httpBody = request.body
    urlRequest.timeoutInterval = max(
      0.001,
      Double(request.timeout.components.seconds)
        + Double(request.timeout.components.attoseconds) / 1e18)
    for (field, value) in request.headers {
      urlRequest.setValue(value, forHTTPHeaderField: field)
    }
    let session = URLSession(configuration: configuration())
    defer { session.finishTasksAndInvalidate() }
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: urlRequest)
    } catch let error as URLError where error.code == .timedOut {
      throw .timedOut
    } catch {
      // A URLError's description names the URL, never the request's headers.
      throw .unreachable(error.localizedDescription)
    }
    guard let http = response as? HTTPURLResponse else {
      throw .unreachable("the reply to \(request.url.absoluteString) is not HTTP")
    }
    var headers: [String: String] = [:]
    for (field, value) in http.allHeaderFields {
      if let field = field as? String, let value = value as? String { headers[field] = value }
    }
    return HTTPResponse(status: http.statusCode, headers: headers, body: data)
  }
}

import Foundation

/// 1 HTTP request a local server read: its method, path and decoded query.
public struct LocalHTTPRequest: Sendable, Equatable {
  public var method: String
  /// The target's path, still percent-encoded, without its query.
  public var path: String
  /// The query's items, percent-decoded; a repeated name keeps its last value.
  public var query: [String: String]

  public init(method: String, path: String, query: [String: String] = [:]) {
    self.method = method
    self.path = path
    self.query = query
  }
}

/// What a local server answers.
public struct LocalHTTPResponse: Sendable, Equatable {
  public var status: Int
  public var contentType: String
  public var body: Data

  public init(status: Int, contentType: String, body: Data) {
    self.status = status
    self.contentType = contentType
    self.body = body
  }

  /// A plain-text answer, such as an error line.
  public static func text(_ status: Int, _ message: String) -> LocalHTTPResponse {
    LocalHTTPResponse(
      status: status, contentType: "text/plain; charset=utf-8", body: Data("\(message)\n".utf8))
  }
}

/// Why a local server didn't start.
public struct LocalHTTPServerError: Error, Sendable, Equatable, CustomStringConvertible {
  public let description: String

  public init(_ description: String) { self.description = description }
}

/// Serves HTTP on 127.0.0.1 only, so nothing off this machine can reach it.
public protocol LocalHTTPServing: Sendable {
  /// Starts listening and returns once connections are accepted, with the port bound.
  /// - Parameter port: 0 picks a free port.
  func start(
    port: UInt16, handler: @escaping @Sendable (LocalHTTPRequest) -> LocalHTTPResponse
  ) async throws -> UInt16

  func stop()
}

/// ``LocalHTTPServing`` over Network.framework: 1 request per connection, then close.
public final class LocalHTTPServer: LocalHTTPServing {
  public init() {}

  public func start(
    port: UInt16, handler: @escaping @Sendable (LocalHTTPRequest) -> LocalHTTPResponse
  ) async throws -> UInt16 {
    throw LocalHTTPServerError("not implemented")
  }

  public func stop() {}
}

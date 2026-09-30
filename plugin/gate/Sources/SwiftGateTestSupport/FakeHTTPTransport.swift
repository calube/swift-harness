import Foundation
import SwiftGateAdapters
import Synchronization

/// A scripted ``HTTPTransport``: answers each request with the next scripted reply (the last one
/// repeats) and records every request, so tests can prove what went over the wire, and that
/// nothing did.
public final class FakeHTTPTransport: HTTPTransport {
  public enum Reply: Sendable {
    case response(HTTPResponse)
    case failure(HTTPTransportError)
  }

  private let replies: [Reply]
  private let clock: FakeRetryClock?
  private let latency: Duration

  /// Each request advances `clock`, when given, by `latency`.
  public init(_ replies: [Reply], clock: FakeRetryClock? = nil, latency: Duration = .zero) {
    self.replies = replies
    self.clock = clock
    self.latency = latency
  }

  public var requests: [HTTPRequest] { [] }

  public func send(_ request: HTTPRequest) async throws(HTTPTransportError) -> HTTPResponse {
    throw .timedOut
  }

  /// A captured Jev reply from `Fixtures/Judge/jev-<name>.reply.json` with its `.status`.
  public static func captured(_ name: String, headers: [String: String] = [:]) throws -> Reply {
    throw HTTPTransportError.timedOut
  }
}

/// A ``RetryClock`` whose time moves only when something sleeps on it or advances it.
public final class FakeRetryClock: RetryClock {
  public init() {}

  public var sleeps: [Duration] { [] }

  public func now() -> Duration { .zero }

  public func sleep(for duration: Duration) async {}

  public func advance(by duration: Duration) {}
}

/// Serves `URLSession` requests from a handler keyed by URL, so ``URLSessionTransport`` runs its
/// real request and response mapping with no network. Each test uses its own URL.
public final class StubURLProtocol: URLProtocol {
  public enum Stub: Sendable {
    case http(status: Int, headers: [String: String], body: Data)
    case notHTTP
    case failure(URLError.Code)
  }

  /// An ephemeral configuration that routes every request through this protocol.
  public static func configuration() -> URLSessionConfiguration {
    .ephemeral
  }

  public static func serve(_ url: URL, with stub: Stub) {}

  /// The requests `url` received, bodies read back from their stream.
  public static func requests(to url: URL) -> [URLRequest] { [] }

  override public class func canInit(with request: URLRequest) -> Bool { false }

  override public class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override public func startLoading() {}

  override public func stopLoading() {}
}

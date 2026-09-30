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
  private let recorded = Mutex<[HTTPRequest]>([])

  /// Each request advances `clock`, when given, by `latency`.
  public init(_ replies: [Reply], clock: FakeRetryClock? = nil, latency: Duration = .zero) {
    self.replies = replies
    self.clock = clock
    self.latency = latency
  }

  public var requests: [HTTPRequest] { recorded.withLock { $0 } }

  public func send(_ request: HTTPRequest) async throws(HTTPTransportError) -> HTTPResponse {
    let index = recorded.withLock {
      $0.append(request)
      return $0.count - 1
    }
    clock?.advance(by: latency)
    guard let last = replies.last else { throw .unreachable("no scripted reply") }
    switch index < replies.count ? replies[index] : last {
    case .response(let response): return response
    case .failure(let error): throw error
    }
  }

  /// A captured Jev reply from `Fixtures/Judge/jev-<name>.reply.json` with its `.status`.
  public static func captured(_ name: String, headers: [String: String] = [:]) throws -> Reply {
    let status = try Fixture.text("Judge/jev-\(name).status")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return .response(
      HTTPResponse(
        status: Int(status) ?? -1, headers: headers,
        body: try Fixture.data("Judge/jev-\(name).reply.json")))
  }
}

/// A ``RetryClock`` whose time moves only when something sleeps on it or advances it.
public final class FakeRetryClock: RetryClock {
  private let state = Mutex<(now: Duration, sleeps: [Duration])>((.zero, []))

  public init() {}

  public var sleeps: [Duration] { state.withLock { $0.sleeps } }

  public func now() -> Duration { state.withLock { $0.now } }

  public func sleep(for duration: Duration) async {
    state.withLock {
      $0.now += duration
      $0.sleeps.append(duration)
    }
  }

  public func advance(by duration: Duration) {
    state.withLock { $0.now += duration }
  }
}

/// Serves `URLSession` requests from a handler keyed by URL, so ``URLSessionTransport`` runs its
/// real request and response mapping with no network. Each test uses its own URL.
public final class StubURLProtocol: URLProtocol {
  public enum Stub: Sendable {
    case http(status: Int, headers: [String: String], body: Data)
    case notHTTP
    case failure(URLError.Code)
  }

  private static let stubs = Mutex<[String: Stub]>([:])
  private static let received = Mutex<[String: [URLRequest]]>([:])

  /// An ephemeral configuration that routes every request through this protocol.
  public static func configuration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return configuration
  }

  public static func serve(_ url: URL, with stub: Stub) {
    stubs.withLock { $0[url.absoluteString] = stub }
  }

  /// The requests `url` received, bodies read back from their stream.
  public static func requests(to url: URL) -> [URLRequest] {
    received.withLock { $0[url.absoluteString] ?? [] }
  }

  override public class func canInit(with request: URLRequest) -> Bool { true }

  override public class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override public func startLoading() {
    guard let url = request.url else { return }
    var copy = request
    copy.httpBody = request.httpBody ?? request.httpBodyStream.map(Self.read)
    Self.received.withLock { $0[url.absoluteString, default: []].append(copy) }
    switch Self.stubs.withLock({ $0[url.absoluteString] }) {
    case .http(let status, let headers, let body):
      if let response = HTTPURLResponse(
        url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
      {
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      }
      client?.urlProtocol(self, didLoad: body)
      client?.urlProtocolDidFinishLoading(self)
    case .notHTTP:
      let response = URLResponse(
        url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocolDidFinishLoading(self)
    case .failure(let code):
      client?.urlProtocol(self, didFailWithError: URLError(code))
    case nil:
      client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
    }
  }

  override public func stopLoading() {}

  private static func read(_ stream: InputStream) -> Data {
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      guard count > 0 else { break }
      data.append(buffer, count: count)
    }
    return data
  }
}

import Foundation
import HTTPClient
import HTTPClientLive
import Synchronization
import Testing

final class StubURLProtocol: URLProtocol {
  static let received = Mutex<[URLRequest]>([])

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.received.withLock { $0.append(request) }
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 418, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "text/plain"]
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data("short and stout".utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

struct HTTPClientLiveTests {
  @Test(
    "the live transport forwards the request and returns the raw response — catches headers or status lost in URLSession bridging"
  )
  func forwardsRequestAndResponse() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let client = HTTPClient.live(session: URLSession(configuration: configuration))
    var request = URLRequest(url: URL(string: "https://example.com/teapot")!)
    request.setValue("sample", forHTTPHeaderField: "X-Client")

    let (data, response) = try await client.send(request)

    #expect(response.statusCode == 418)
    #expect(String(decoding: data, as: UTF8.self) == "short and stout")
    let forwarded = StubURLProtocol.received.withLock { $0 }
    #expect(forwarded.map { $0.value(forHTTPHeaderField: "X-Client") } == ["sample"])
  }
}

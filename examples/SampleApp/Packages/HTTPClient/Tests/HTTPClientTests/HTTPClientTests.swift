import Foundation
import HTTPClient
import Testing

struct HTTPClientTests {
  static let url = URL(string: "https://example.com/resource")!

  static func client(status: Int, body: Data = Data()) -> HTTPClient {
    HTTPClient(send: { request in
      (
        body,
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
      )
    })
  }

  @Test("2xx responses return the body — catches successful responses being treated as failures")
  func successReturnsBody() async throws {
    let data = try await Self.client(status: 204, body: Data("ok".utf8)).data(
      for: URLRequest(url: Self.url))
    #expect(data == Data("ok".utf8))
  }

  @Test("non-2xx responses throw the status code — catches error pages being decoded as data")
  func failureStatusThrows() async {
    for status in [199, 301, 404, 503] {
      await #expect(throws: HTTPError.unacceptableStatus(status)) {
        try await Self.client(status: status).data(for: URLRequest(url: Self.url))
      }
    }
  }
}

import APIClient
import APIClientLive
import Foundation
import Synchronization
import Testing

func fixture(_ name: String) throws -> Data {
  let url = try #require(
    Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
  return try Data(contentsOf: url)
}

/// Answers every request with one canned reply and records what was asked.
final class RecordingTransport: Sendable {
  enum Reply: Sendable {
    case status(Int, Data = Data())
    case failure(URLError.Code)
  }

  private let reply: Reply
  private let received = Mutex<[URLRequest]>([])

  init(_ reply: Reply) {
    self.reply = reply
  }

  var requests: [URLRequest] { received.withLock { $0 } }

  var client: APIClient {
    APIClient.live(transport: { request in
      self.received.withLock { $0.append(request) }
      switch self.reply {
      case .status(let code, let body):
        let response = HTTPURLResponse(
          url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
        return (body, response)
      case .failure(let code):
        throw URLError(code)
      }
    })
  }
}

struct APIClientLiveTests {
  @Test("a captured posts response decodes into posts — catches a JSON key mapping regression")
  func decodesCapturedResponse() async throws {
    let transport = RecordingTransport(.status(200, try fixture("posts")))

    let posts = try await transport.client.fetchPosts()

    #expect(posts.map(\.id) == [1, 2, 3])
    #expect(posts.first?.userId == 1)
    #expect(posts[1].title == "qui est esse")
    #expect(
      transport.requests.map(\.url?.absoluteString) == [
        "https://jsonplaceholder.typicode.com/posts"
      ])
    #expect(transport.requests.first?.value(forHTTPHeaderField: "Accept") == "application/json")
  }

  @Test("a non-2xx status throws badStatus — catches an error page being decoded as posts")
  func badStatusThrows() async {
    for status in [404, 500] {
      let transport = RecordingTransport(.status(status, Data("[]".utf8)))
      await #expect(throws: APIError.badStatus(status)) { try await transport.client.fetchPosts() }
    }
  }

  @Test(
    "no connection throws offline — catches a lost connection surfacing as a raw transport error")
  func noConnectionIsOffline() async {
    for code in [URLError.Code.notConnectedToInternet, .timedOut] {
      let transport = RecordingTransport(.failure(code))
      await #expect(throws: APIError.offline) { try await transport.client.fetchPosts() }
    }
  }

  @Test("a body that isn't a post array throws undecodable — catches a decoding crash or hang")
  func malformedBodyIsUndecodable() async {
    let transport = RecordingTransport(.status(200, Data(#"{"error":"nope"}"#.utf8)))
    await #expect(throws: APIError.undecodable) { try await transport.client.fetchPosts() }
  }
}

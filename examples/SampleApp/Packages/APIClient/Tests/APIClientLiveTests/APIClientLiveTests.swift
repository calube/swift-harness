import APIClient
import APIClientLive
import Clocks
import ConcurrencyExtras
import Foundation
import HTTPClient
import Synchronization
import Testing

/// Scripted fake transport: returns the queued responses in order and records every request.
final class ScriptedTransport: Sendable {
  enum Reply: Sendable {
    case status(Int, Data = Data())
    case transportError(URLError.Code)
  }

  private let state: Mutex<(replies: [Reply], requests: [URLRequest])>

  init(_ replies: [Reply]) {
    state = Mutex((replies, []))
  }

  var requests: [URLRequest] { state.withLock { $0.requests } }

  var client: HTTPClient {
    HTTPClient(send: { request in
      let reply = self.state.withLock { state in
        state.requests.append(request)
        return state.replies.removeFirst()
      }
      switch reply {
      case .status(let code, let body):
        return (
          body,
          HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
        )
      case .transportError(let code):
        throw URLError(code)
      }
    })
  }
}

func fixture(_ name: String) throws -> Data {
  let url = try #require(
    Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
  return try Data(contentsOf: url)
}

// `.serialized` because `withMainSerialExecutor` swaps a process-global executor hook; it makes
// `TestClock.advance` deterministic by running the retrying task to its next sleep before advancing.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct APIClientLiveTests {
  @Test("a captured catfact response decodes into a Fact — catches a JSON key mapping regression")
  func decodesCapturedResponse() async throws {
    let transport = ScriptedTransport([.status(200, try fixture("catfact-fact"))])
    let client = APIClient.live(http: transport.client, clock: TestClock())

    let fact = try await client.randomFact()

    #expect(fact.text.hasPrefix("Cat families usually play best in even numbers."))
    #expect(transport.requests.map(\.url?.absoluteString) == ["https://catfact.ninja/fact"])
    #expect(transport.requests.first?.value(forHTTPHeaderField: "Accept") == "application/json")
  }

  @Test(
    "server errors retry with exponential backoff on the injected clock — catches retries hammering the server without delay"
  )
  func retriesWithBackoff() async throws {
    try await withMainSerialExecutor {
      let transport = ScriptedTransport([
        .status(503), .transportError(.networkConnectionLost),
        .status(200, try fixture("catfact-fact")),
      ])
      let clock = TestClock()
      let client = APIClient.live(
        http: transport.client, clock: clock,
        retry: RetryPolicy(maxAttempts: 3, baseDelay: .seconds(1)))

      let task = Task { try await client.randomFact() }
      defer { task.cancel() }

      await clock.advance(by: .milliseconds(999))
      #expect(transport.requests.count == 1)
      await clock.advance(by: .milliseconds(1))
      #expect(transport.requests.count == 2)
      await clock.advance(by: .milliseconds(1999))
      #expect(transport.requests.count == 2)
      await clock.advance(by: .milliseconds(1))
      let fact = try await task.value
      #expect(transport.requests.count == 3)
      #expect(fact.text.isEmpty == false)
    }
  }

  @Test("client errors are not retried — catches a 4xx being retried and duplicating the request")
  func clientErrorNotRetried() async {
    let transport = ScriptedTransport([.status(404), .status(200)])
    let client = APIClient.live(http: transport.client, clock: TestClock())

    await #expect(throws: HTTPError.unacceptableStatus(404)) { try await client.randomFact() }
    #expect(transport.requests.count == 1)
  }

  @Test(
    "retries stop at the attempt limit and surface the last error — catches an unbounded retry loop"
  )
  func givesUpAfterMaxAttempts() async throws {
    try await withMainSerialExecutor {
      let transport = ScriptedTransport([.status(500), .status(502), .status(503), .status(200)])
      let clock = TestClock()
      let client = APIClient.live(
        http: transport.client, clock: clock,
        retry: RetryPolicy(maxAttempts: 3, baseDelay: .seconds(1)))

      let task = Task { try await client.randomFact() }
      defer { task.cancel() }
      await clock.advance(by: .seconds(1))
      await clock.advance(by: .seconds(2))

      await #expect(throws: HTTPError.unacceptableStatus(503)) { try await task.value }
      #expect(transport.requests.count == 3)
    }
  }
}

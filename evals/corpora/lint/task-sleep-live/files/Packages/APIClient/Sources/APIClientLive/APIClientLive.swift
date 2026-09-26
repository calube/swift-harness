import APIClient
import Dependencies
import Foundation
import HTTPClient

public struct RetryPolicy: Sendable {
  public var maxAttempts: Int
  public var baseDelay: Duration

  public init(maxAttempts: Int, baseDelay: Duration) {
    self.maxAttempts = maxAttempts
    self.baseDelay = baseDelay
  }

  public static let standard = RetryPolicy(maxAttempts: 3, baseDelay: .milliseconds(500))

  /// Only failures a later attempt can plausibly fix: transport errors, throttling, and 5xx.
  func isRetryable(_ error: any Error) -> Bool {
    switch error {
    case HTTPError.unacceptableStatus(let status): status == 429 || (500..<600).contains(status)
    case is URLError: true
    default: false
    }
  }

  func delay(beforeRetry retry: Int) -> Duration {
    baseDelay * (1 << (retry - 1))
  }
}

private struct CatFactResponse: Decodable {
  var fact: String
}

extension APIClient {
  static let baseURL = URL(string: "https://catfact.ninja")!

  public static func live(
    http: HTTPClient,
    clock: any Clock<Duration>,
    retry: RetryPolicy = .standard
  ) -> Self {
    Self(randomFact: {
      var request = URLRequest(url: baseURL.appending(path: "fact"))
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      let data = try await withRetry(retry, clock: clock) { [request] in
        try await http.data(for: request)
      }
      return Fact(text: try JSONDecoder().decode(CatFactResponse.self, from: data).fact)
    })
  }

  private static func withRetry<T: Sendable>(
    _ policy: RetryPolicy,
    clock: any Clock<Duration>,
    operation: @Sendable () async throws -> T
  ) async throws -> T {
    var attempt = 1
    while true {
      do {
        return try await operation()
      } catch  where attempt < policy.maxAttempts && policy.isRetryable(error) {
        try await clock.sleep(for: policy.delay(beforeRetry: attempt))
        attempt += 1
      }
    }
  }
}

extension APIClient: DependencyKey {
  /// Resolved per call so the transport and clock come from the caller's dependency context.
  public static let liveValue = APIClient(randomFact: {
    @Dependency(\.httpClient) var http
    @Dependency(\.continuousClock) var clock
    return try await APIClient.live(http: http, clock: clock).randomFact()
  })
}

func seededProbe() async throws {
  try await Task.sleep(for: .seconds(1))
}

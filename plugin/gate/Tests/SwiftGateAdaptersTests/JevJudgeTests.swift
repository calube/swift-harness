import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("Jev judge over HTTP")
struct JevJudgeTests {
  static let key = "sk-sentinel-3f9c1d7e"
  static let environment = [JevPin.keyVariable: key]

  /// A subject from a labelled case directory, as the captures built it.
  static func caseSubject(_ name: String) throws -> JudgeSubject {
    let directory = Fixture.gateDirectory.appending(path: "Fixtures/judge/cases/\(name)")
    return JudgeSubject(
      id: name, file: "Tests/\(name).swift", line: 1,
      source: String(
        decoding: try Data(contentsOf: directory.appending(path: "Test.swift.txt")), as: UTF8.self),
      context: String(
        decoding: try Data(contentsOf: directory.appending(path: "Change.diff")), as: UTF8.self),
      declaredTier: "T1")
  }

  static func judge(
    _ replies: [FakeHTTPTransport.Reply], model: String = JevPin.model,
    environment: [String: String] = environment, clock: FakeRetryClock = FakeRetryClock(),
    latency: Duration = .zero
  ) -> (JevJudge, FakeHTTPTransport) {
    let transport = FakeHTTPTransport(replies, clock: clock, latency: latency)
    return (
      JevJudge(model: model, transport: transport, environment: environment, clock: clock),
      transport
    )
  }

  static func response(_ status: Int, _ body: String, headers: [String: String] = [:])
    -> FakeHTTPTransport.Reply
  {
    .response(HTTPResponse(status: status, headers: headers, body: Data(body.utf8)))
  }

  /// A captured reply with `edit` applied to its text.
  static func edited(_ name: String, _ edit: (String) -> String) throws -> FakeHTTPTransport.Reply {
    response(200, edit(try Fixture.text("Judge/jev-\(name).reply.json")))
  }

  static func sortedJSON(_ data: Data) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: try JSONSerialization.jsonObject(with: data),
      options: [.sortedKeys, .withoutEscapingSlashes])
  }

  static func error(_ body: () async throws(JudgeError) -> Void) async -> JudgeError? {
    do {
      try await body()
      return nil
    } catch {
      return error
    }
  }

  static func distribution(_ answers: [JudgeAnswer], _ question: String) -> [String: Double] {
    answers.first { $0.question == question }?.distribution ?? [:]
  }

  // MARK: - Replies

  @Test(
    "each captured 200 reply decodes to distributions with no rationale — catches a Noul probability read as no, or a Choice or Score option dropped"
  )
  func capturedRepliesDecode() async throws {
    let (tests, _) = Self.judge([try FakeHTTPTransport.captured("test-quality")])
    let answers = try await tests.answer(
      try Self.caseSubject("counter-increment"), questions: .tests)
    #expect(Self.distribution(answers, "fails-if-broken") == ["yes": 0.91, "no": 1 - 0.91])
    #expect(Self.distribution(answers, "asserts-implementation") == ["yes": 0.27, "no": 1 - 0.27])
    #expect(Self.distribution(answers, "tier") == ["T1": 1, "T2": 0, "T3": 0])
    #expect(
      Self.distribution(answers, "name-specificity") == ["vague": 0, "partial": 0, "specific": 1])
    #expect(answers.allSatisfy { $0.rationale == nil })

    let (comments, _) = Self.judge([try FakeHTTPTransport.captured("comments")])
    let commentAnswers = try await comments.answer(
      try Self.caseSubject("counter-increment"), questions: .comments)
    #expect(Self.distribution(commentAnswers, "loses-fact") == ["yes": 0.31, "no": 1 - 0.31])
    #expect(Self.distribution(commentAnswers, "right-size") == ["yes": 0.81, "no": 1 - 0.81])
  }

  @Test(
    "Score probabilities keyed \"0\", \"1\", \"2\" map by key whatever their order — catches levels mapped by position in the reply"
  )
  func scoreKeysMapByIndex() async throws {
    let reordered = try Self.edited("alias") {
      $0.replacing(
        #""probabilities":{"0":0.32,"1":0.06,"2":0.62}"#,
        with: #""probabilities":{"2":0.62,"1":0.06,"0":0.32}"#)
    }
    let (judge, _) = Self.judge([reordered])
    let answers = try await judge.answer(try Self.caseSubject("own-double"), questions: .tests)
    #expect(
      Self.distribution(answers, "name-specificity") == [
        "vague": 0.32, "partial": 0.06, "specific": 0.62,
      ])
  }

  @Test(
    "a Score legend with its levels reordered fails naming the question — catches a level-to-option swap"
  )
  func reorderedLegendFails() async throws {
    let swapped = try Self.edited("test-quality") {
      $0.replacing(
        #""legend":{"0":"vague","1":"partial","2":"specific"}"#,
        with: #""legend":{"0":"specific","1":"partial","2":"vague"}"#)
    }
    let (judge, _) = Self.judge([swapped])
    let subject = try Self.caseSubject("counter-increment")
    let error = await Self.error { () async throws(JudgeError) in
      _ = try await judge.answer(subject, questions: .tests)
    }
    guard case .malformedReply(let message) = error else {
      Issue.record("expected malformedReply, got \(String(describing: error))")
      return
    }
    #expect(message.contains("name-specificity"))
  }

  @Test(
    "a served model other than the requested one is malformedReply naming both — catches an alias answering under the pin's cache key"
  )
  func servedModelMustMatch() async throws {
    let (judge, _) = Self.judge([try FakeHTTPTransport.captured("alias")], model: "jev-latest")
    let subject = try Self.caseSubject("own-double")
    let error = await Self.error { () async throws(JudgeError) in
      _ = try await judge.answer(subject, questions: .tests)
    }
    guard case .malformedReply(let message) = error else {
      Issue.record("expected malformedReply, got \(String(describing: error))")
      return
    }
    #expect(message.contains("jev-latest") && message.contains("jev-1.13.0"))
  }

  @Test(
    "the pin, and the model a jev config with no model gets, is the model Jev served in the captures — catches a pin bump without a new price"
  )
  func pinMatchesCapturedServedModel() throws {
    let defaulted = JudgeFactory.make(
      .enabled(backend: .jev, thresholds: JudgeThresholds(advisory: 0.6, block: 0.9)),
      runner: FakeProcessRunner { _ throws(ProcessRunnerError) in
        ProcessOutput(status: .exited(0), stdout: "", stderr: "")
      }, cacheDirectory: nil, transport: FakeHTTPTransport([]), environment: [:])
    for name in ["test-quality", "comments", "alias"] {
      let reply =
        try JSONSerialization.jsonObject(with: Fixture.data("Judge/jev-\(name).reply.json"))
        as? [String: Any]
      #expect(reply?["model"] as? String == JevPin.model, "\(name)")
      #expect(reply?["model"] as? String == defaulted?.identity.model, "\(name)")
    }
  }

  // MARK: - Request

  @Test(
    "the built request equals each captured request after key sorting, in 1 POST with the key as a bearer token — catches drift between the tests' request and the one that went over the wire"
  )
  func requestMatchesCapture() async throws {
    // The alias capture asked for jev-latest, so its reply's served model fails the pin check.
    let captures: [(request: String, subject: JudgeSubject, answers: Bool)] = [
      ("test-quality", try Self.caseSubject("counter-increment"), true),
      ("alias", try Self.caseSubject("own-double"), false),
    ]
    for capture in captures {
      let captured = try Fixture.data("Judge/jev-request-\(capture.request).json")
      let model =
        (try JSONSerialization.jsonObject(with: captured) as? [String: Any])?["model"] as? String
      let (judge, transport) = Self.judge(
        [try FakeHTTPTransport.captured(capture.request)], model: model ?? "")
      let failure = await Self.error { () async throws(JudgeError) in
        _ = try await judge.answer(capture.subject, questions: .tests)
      }
      #expect(
        (failure == nil) == capture.answers, "\(capture.request): \(String(describing: failure))")
      let sent = try #require(transport.requests.count == 1 ? transport.requests.first : nil)
      #expect(try Self.sortedJSON(sent.body) == Self.sortedJSON(captured), "\(capture.request)")
      #expect(sent.method == "POST")
      #expect(sent.url.absoluteString == "https://api.typesafe.ai/v1/systemone")
      #expect(sent.headers["Authorization"] == "Bearer \(Self.key)")
      #expect(sent.headers["Content-Type"] == "application/json")
    }
  }

  @Test(
    "the comment set's request equals its capture — catches Noul questions sent with criteria or a state with a tier it doesn't have"
  )
  func commentRequestMatchesCapture() async throws {
    let captured = try Fixture.data("Judge/jev-request-comments.json")
    let state =
      (try JSONSerialization.jsonObject(with: captured) as? [String: Any])?["state"]
      as? [String: String] ?? [:]
    let subject = JudgeSubject(
      id: "Judge.swift:1", file: "Judge.swift", line: 1, source: state["subject"] ?? "",
      context: state["context"] ?? "")
    let (judge, transport) = Self.judge([try FakeHTTPTransport.captured("comments")])
    _ = try await judge.answer(subject, questions: .comments)
    let sent = try #require(transport.requests.first)
    #expect(try Self.sortedJSON(sent.body) == Self.sortedJSON(captured))
  }

  // MARK: - Errors

  @Test(
    "the captured 401 is a backend error naming the key variable and Jev's message — catches a bad key reported as a bad reply"
  )
  func unauthorizedNamesVariable() async throws {
    let (judge, _) = Self.judge([try FakeHTTPTransport.captured("bad-key")])
    let subject = try Self.caseSubject("counter-increment")
    let error = await Self.error { () async throws(JudgeError) in
      _ = try await judge.answer(subject, questions: .tests)
    }
    guard case .backend(let message) = error else {
      Issue.record("expected backend, got \(String(describing: error))")
      return
    }
    #expect(message.contains("TYPESAFE_API_KEY"))
    #expect(message.contains("Cannot authenticate with the server"))
  }

  @Test(
    "the captured 422 is a backend error carrying Jev's body — catches an invalid request hidden behind a generic message"
  )
  func unprocessableCarriesBody() async throws {
    let (judge, _) = Self.judge([try FakeHTTPTransport.captured("invalid")])
    let subject = try Self.caseSubject("counter-increment")
    let error = await Self.error { () async throws(JudgeError) in
      _ = try await judge.answer(subject, questions: .tests)
    }
    guard case .backend(let message) = error else {
      Issue.record("expected backend, got \(String(describing: error))")
      return
    }
    #expect(message.contains("422"))
    #expect(message.contains("Field required"))
  }

  @Test(
    "the captured 400 max_tokens_exceeded is stateTooLarge — catches Jev's size refusal reported as a malformed reply"
  )
  func oversizeIsTooLarge() async throws {
    let (judge, _) = Self.judge([try FakeHTTPTransport.captured("oversize")])
    let subject = try Self.caseSubject("counter-increment")
    let error = await Self.error { () async throws(JudgeError) in
      _ = try await judge.answer(subject, questions: .tests)
    }
    guard case .stateTooLarge(let tokens) = error else {
      Issue.record("expected stateTooLarge, got \(String(describing: error))")
      return
    }
    #expect(tokens > 0)
  }

  @Test(
    "any other status, or a 200 that isn't the reply shape, is malformedReply — catches a server error read as answers"
  )
  func otherStatusIsMalformed() async throws {
    for reply in [Self.response(500, "upstream failed"), Self.response(200, #"{"answers":[]}"#)] {
      let (judge, _) = Self.judge([reply])
      let subject = try Self.caseSubject("counter-increment")
      let error = await Self.error { () async throws(JudgeError) in
        _ = try await judge.answer(subject, questions: .tests)
      }
      guard case .malformedReply = error else {
        Issue.record("expected malformedReply, got \(String(describing: error))")
        continue
      }
    }
  }

  @Test(
    "a missing or empty key is notConfigured naming TYPESAFE_API_KEY and sends nothing — catches a request without credentials"
  )
  func missingKeySendsNothing() async throws {
    for environment in [[:], [JevPin.keyVariable: ""]] {
      let (judge, transport) = Self.judge(
        [try FakeHTTPTransport.captured("test-quality")], environment: environment)
      let subject = try Self.caseSubject("counter-increment")
      let error = await Self.error { () async throws(JudgeError) in
        _ = try await judge.answer(subject, questions: .tests)
      }
      guard case .notConfigured(let message) = error else {
        Issue.record("expected notConfigured, got \(String(describing: error))")
        continue
      }
      #expect(message.contains("TYPESAFE_API_KEY"))
      #expect(transport.requests.isEmpty)
    }
  }

  @Test(
    "a transport timeout or failed connection is a backend error naming it — catches a hung or refused call reported as a bad reply"
  )
  func transportTimeoutIsBackend() async throws {
    let (judge, _) = Self.judge([.failure(.timedOut)])
    let subject = try Self.caseSubject("counter-increment")
    let error = await Self.error { () async throws(JudgeError) in
      _ = try await judge.answer(subject, questions: .tests)
    }
    guard case .backend(let message) = error else {
      Issue.record("expected backend, got \(String(describing: error))")
      return
    }
    #expect(message.contains("30 s"))

    let (unreachable, _) = Self.judge([.failure(.unreachable("connection refused"))])
    let refused = await Self.error { () async throws(JudgeError) in
      _ = try await unreachable.answer(subject, questions: .tests)
    }
    #expect(refused == .backend("Jev is unreachable: connection refused"))
  }

  // MARK: - Retries

  @Test(
    "a 429 honouring retry-after, then a 529, then 200 succeeds after 2 waits — catches a rate limit failing the judge at once"
  )
  func retriesThenSucceeds() async throws {
    let clock = FakeRetryClock()
    let (judge, transport) = Self.judge(
      [
        Self.response(429, "slow down", headers: ["Retry-After": "3"]),
        Self.response(529, "overloaded"),
        try FakeHTTPTransport.captured("test-quality"),
      ], clock: clock)
    let answers = try await judge.answer(
      try Self.caseSubject("counter-increment"), questions: .tests)
    #expect(answers.count == 4)
    #expect(transport.requests.count == 3)
    #expect(clock.sleeps.first == .seconds(3))
    #expect(clock.sleeps.count == 2)
  }

  @Test(
    "429 on every try fails as a backend error within the timeout — catches retrying forever or past the deadline"
  )
  func rateLimitUntilTimeoutFails() async throws {
    let clock = FakeRetryClock()
    let (judge, transport) = Self.judge(
      [Self.response(429, "slow down")], clock: clock, latency: .milliseconds(200))
    let subject = try Self.caseSubject("counter-increment")
    let error = await Self.error { () async throws(JudgeError) in
      _ = try await judge.answer(subject, questions: .tests)
    }
    guard case .backend(let message) = error else {
      Issue.record("expected backend, got \(String(describing: error))")
      return
    }
    #expect(message.contains("429"))
    #expect(transport.requests.count > 1)
    #expect(clock.now() <= .seconds(30))
    #expect(transport.requests.allSatisfy { $0.timeout <= .seconds(30) })
  }

  // MARK: - Size

  @Test(
    "a 31K-token state fails as stateTooLarge without a request, and a 29K-token one is sent — catches an oversize state sent or trimmed"
  )
  func oversizeStateNeverSent() async throws {
    let (judge, transport) = Self.judge([try FakeHTTPTransport.captured("test-quality")])
    let big = JudgeSubject(
      id: "big", file: "Big.swift", line: 1, source: String(repeating: "a", count: 93_000),
      context: "", declaredTier: "T1")
    let error = await Self.error { () async throws(JudgeError) in
      _ = try await judge.answer(big, questions: .tests)
    }
    guard case .stateTooLarge(let tokens) = error else {
      Issue.record("expected stateTooLarge, got \(String(describing: error))")
      return
    }
    #expect(tokens >= 31_000)
    #expect(transport.requests.isEmpty)

    let fits = JudgeSubject(
      id: "fits", file: "Fits.swift", line: 1, source: String(repeating: "a", count: 87_000),
      context: "", declaredTier: "T1")
    _ = try await judge.answer(fits, questions: .tests)
    #expect(transport.requests.count == 1)
  }

  // MARK: - Usage and the key

  @Test(
    "usage reports Jev's tokens, the pin's input price, the measured wall time and the served model — catches cost or tokens lost for the benchmark"
  )
  func usageFromReply() async throws {
    let clock = FakeRetryClock()
    let (judge, _) = Self.judge(
      [try FakeHTTPTransport.captured("test-quality")], clock: clock,
      latency: .milliseconds(1_250))
    let usage = try #require(
      try await judge.measuredAnswer(try Self.caseSubject("counter-increment"), questions: .tests)
        .usage)
    #expect(usage.inputTokens == 655)
    #expect(usage.outputTokens == 99)
    #expect(usage.costUSD == 655 * JevPin.pricePerMillionInputTokens / 1_000_000)
    #expect(usage.wallMilliseconds == 1_250)
    #expect(usage.backendMilliseconds == nil)
    #expect(usage.servedModel == "jev-1.13.0")
    #expect(usage.cached == false)
  }

  @Test(
    "a model other than the pin reports no cost — catches the pin's price charged for a model it wasn't published for"
  )
  func otherModelHasNoPrice() async throws {
    let reply = try Self.edited("test-quality") {
      $0.replacing(#""model":"jev-1.13.0""#, with: #""model":"jev-1.12.0""#)
    }
    let (judge, _) = Self.judge([reply], model: "jev-1.12.0")
    let usage = try await judge.measuredAnswer(
      try Self.caseSubject("counter-increment"), questions: .tests
    ).usage
    #expect(usage?.inputTokens == 655)
    #expect(usage?.costUSD == nil)
  }

  @Test(
    "a sentinel key reaches the Authorization header and no error, description, cache file or usage value — catches a key leak"
  )
  func keyNeverLeaks() async throws {
    let echo = "you sent Authorization: Bearer \(Self.key)"
    for reply in [Self.response(422, echo), Self.response(500, echo), Self.response(401, echo)] {
      let (judge, transport) = Self.judge([reply])
      let subject = try Self.caseSubject("counter-increment")
      let error = await Self.error { () async throws(JudgeError) in
        _ = try await judge.answer(subject, questions: .tests)
      }
      #expect(transport.requests.first?.headers["Authorization"] == "Bearer \(Self.key)")
      #expect(error != nil)
      #expect(!"\(String(describing: error))".contains(Self.key))
      #expect(!"\(transport.requests)".contains(Self.key))
      var dumped = ""
      dump(judge, to: &dumped)
      #expect(!"\(judge) \(String(reflecting: judge)) \(dumped)".contains(Self.key))
    }

    let cache = FileManager.default.temporaryDirectory.appending(
      path: "jev-cache-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: cache) }
    let (inner, _) = Self.judge([try FakeHTTPTransport.captured("test-quality")])
    let judge = CachingJudge(inner, cache: FileJudgeCache(directory: cache))
    let reply = try await judge.measuredAnswer(
      try Self.caseSubject("counter-increment"), questions: .tests)
    let usage = String(decoding: try JSONEncoder().encode(reply.usage), as: UTF8.self)
    #expect(!usage.contains(Self.key))
    let files = try FileManager.default.contentsOfDirectory(
      at: cache, includingPropertiesForKeys: nil)
    #expect(!files.isEmpty)
    for file in files {
      #expect(!String(decoding: try Data(contentsOf: file), as: UTF8.self).contains(Self.key))
    }
  }

  // MARK: - Factory

  @Test(
    "the factory builds Jev at the pin with the given transport and environment — catches the placeholder or the \"unset\" model surviving"
  )
  func factoryBuildsPinnedJev() async throws {
    let transport = FakeHTTPTransport([try FakeHTTPTransport.captured("test-quality")])
    let config = JudgeConfig.enabled(
      backend: .jev, thresholds: JudgeThresholds(advisory: 0.6, block: 0.9))
    let runner = FakeProcessRunner { _ throws(ProcessRunnerError) in
      ProcessOutput(status: .exited(0), stdout: "", stderr: "")
    }
    let judge = try #require(
      JudgeFactory.make(
        config, runner: runner, cacheDirectory: nil, transport: transport,
        environment: Self.environment))
    #expect(judge.identity == JudgeIdentity(backend: "jev", model: "jev-1.13.0"))
    _ = try await judge.answer(try Self.caseSubject("counter-increment"), questions: .tests)
    #expect(transport.requests.count == 1)
    #expect(runner.invocations.isEmpty)

    let unkeyed = FakeHTTPTransport([try FakeHTTPTransport.captured("test-quality")])
    let blocked = JudgeFactory.make(
      config, runner: runner, cacheDirectory: nil, transport: unkeyed, environment: [:])
    let subject = try Self.caseSubject("counter-increment")
    let error = await Self.error { () async throws(JudgeError) in
      _ = try await blocked?.answer(subject, questions: .tests)
    }
    #expect(error?.verdict == .blocked)
    #expect(unkeyed.requests.isEmpty)
  }

  // MARK: - Live transport and clock

  @Test(
    "the URLSession transport sends the method, headers, body and timeout and returns status, lowercased headers and body — catches a request mapped wrong on the live path"
  )
  func urlSessionRoundTrip() async throws {
    let url = try #require(URL(string: "https://stub.invalid/round-trip"))
    StubURLProtocol.serve(
      url, with: .http(status: 429, headers: ["Retry-After": "2"], body: Data("slow".utf8)))
    let transport = URLSessionTransport(configuration: { StubURLProtocol.configuration() })
    let response = try await transport.send(
      HTTPRequest(
        method: "POST", url: url, headers: ["Authorization": "Bearer \(Self.key)"],
        body: Data("{}".utf8), timeout: .milliseconds(2_500)))
    #expect(response.status == 429)
    #expect(response.headers["retry-after"] == "2")
    #expect(response.body == Data("slow".utf8))
    let sent = try #require(StubURLProtocol.requests(to: url).first)
    #expect(sent.httpMethod == "POST")
    #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.key)")
    #expect(sent.httpBody == Data("{}".utf8))
    #expect(sent.timeoutInterval == 2.5)
  }

  @Test(
    "the URLSession transport maps a timeout, a failed connection and a non-HTTP reply to transport errors — catches a network failure escaping untyped"
  )
  func urlSessionFailures() async throws {
    let transport = URLSessionTransport(configuration: { StubURLProtocol.configuration() })
    let cases: [(String, StubURLProtocol.Stub, HTTPTransportError?)] = [
      ("timed-out", .failure(.timedOut), .timedOut),
      ("refused", .failure(.cannotConnectToHost), nil),
      ("not-http", .notHTTP, nil),
    ]
    for (name, stub, expected) in cases {
      let url = try #require(URL(string: "https://stub.invalid/\(name)"))
      StubURLProtocol.serve(url, with: stub)
      do {
        _ = try await transport.send(
          HTTPRequest(method: "POST", url: url, headers: [:], body: Data(), timeout: .seconds(5)))
        Issue.record("\(name): expected a transport error")
      } catch {
        if let expected {
          #expect(error == expected, "\(name)")
        } else {
          guard case .unreachable = error else {
            Issue.record("\(name): expected unreachable, got \(error)")
            continue
          }
        }
      }
    }
  }

  @Test(
    "with the live clock a retry-after of 0 retries at once and succeeds — catches the live backoff never returning"
  )
  func liveClockRetries() async throws {
    let transport = FakeHTTPTransport([
      Self.response(529, "overloaded", headers: ["retry-after": "0"]),
      try FakeHTTPTransport.captured("test-quality"),
    ])
    let judge = JevJudge(model: JevPin.model, transport: transport, environment: Self.environment)
    let reply = try await judge.measuredAnswer(
      try Self.caseSubject("counter-increment"), questions: .tests)
    #expect(transport.requests.count == 2)
    #expect(reply.usage?.wallMilliseconds ?? -1 >= 0)
  }

  @Test(
    "a Score level with no option, or an answer of the wrong type, is malformedReply naming the question — catches an answer mapped to a level or kind it isn't"
  )
  func wrongLevelOrTypeFails() async throws {
    let edits: [(String, String, String)] = [
      (
        #""probabilities":{"0":0.0,"1":0.0,"2":1.0}"#,
        #""probabilities":{"0":0.0,"1":0.0,"3":1.0}"#,
        "name-specificity"
      ),
      (
        #""fails-if-broken":{"type":"noul","noul":0.91}"#,
        #""fails-if-broken":{"type":"choice","choice":"T1","confidence":1.0,"probabilities":{"T1":1.0}}"#,
        "fails-if-broken"
      ),
    ]
    for (from, to, question) in edits {
      let (judge, _) = Self.judge([try Self.edited("test-quality") { $0.replacing(from, with: to) }]
      )
      let subject = try Self.caseSubject("counter-increment")
      let error = await Self.error { () async throws(JudgeError) in
        _ = try await judge.answer(subject, questions: .tests)
      }
      guard case .malformedReply(let message) = error else {
        Issue.record("\(question): expected malformedReply, got \(String(describing: error))")
        continue
      }
      #expect(message.contains(question))
    }
  }
}

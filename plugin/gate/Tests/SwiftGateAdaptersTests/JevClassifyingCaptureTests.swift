import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("Jev's captured diff-risk and finding-severity replies")
struct JevClassifyingCaptureTests {
  static let environment = [JevPin.keyVariable: "sk-sentinel-3f9c1d7e"]

  static func jev(_ replies: [FakeHTTPTransport.Reply]) -> (JevJudge, FakeHTTPTransport) {
    let transport = FakeHTTPTransport(replies, clock: FakeRetryClock())
    return (
      JevJudge(
        model: JevPin.model, transport: transport, environment: environment,
        clock: FakeRetryClock()),
      transport
    )
  }

  static func sortedJSON(_ data: Data) throws -> String {
    let object = try JSONSerialization.jsonObject(with: data)
    return String(
      decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
      as: UTF8.self)
  }

  /// The change a diff-risk capture was asked about, read back from its request's state.
  static func change(_ name: String) throws -> DiffRiskChange {
    let request = try Fixture.data("Judge/jev-request-diff-risk-\(name).json")
    let state =
      (try JSONSerialization.jsonObject(with: request) as? [String: Any])?["state"]
      as? [String: String] ?? [:]
    let paths = (state["context"] ?? "").split(separator: "\n").dropFirst().map(String.init)
    return DiffRiskChange(id: "change", paths: paths, diff: state["subject"] ?? "")
  }

  /// The review finding a finding-severity capture was asked about, from its review fixture.
  static func finding(_ focus: String, _ index: Int) throws -> Finding {
    let object =
      try JSONSerialization.jsonObject(
        with: Fixture.data("Review/dismiss-race/\(focus).json")) as? [String: Any]
    let found = try #require((object?["findings"] as? [[String: Any]])?[index])
    return try Finding(
      ruleID: found["rule"] as? String ?? "", severity: .nit, file: found["file"] as? String ?? "",
      line: found["line"] as? Int, message: found["title"] as? String ?? "",
      failureScenario: found["failure_scenario"] as? String)
  }

  static func risk(
    _ change: DiffRiskChange, sensitive: [String],
    ask: (JudgeSubject, JudgeQuestionSet) async throws -> [JudgeAnswer]
  ) async -> Result<DiffRiskVerdict, JudgeClassificationError> {
    do throws(JudgeClassificationError) {
      return .success(try await DiffRisk.classify(change, sensitive: sensitive, ask: ask))
    } catch {
      return .failure(error)
    }
  }

  static func severity(
    _ finding: Finding, diff: String,
    ask: (JudgeSubject, JudgeQuestionSet) async throws -> [JudgeAnswer]
  ) async -> Result<Severity, JudgeClassificationError> {
    do throws(JudgeClassificationError) {
      return .success(try await FindingSeverity.classify(finding, diff: diff, ask: ask))
    } catch {
      return .failure(error)
    }
  }

  @Test(
    "each captured diff-risk reply reads as its level, from a request equal to its capture — catches a level read from the wrong key"
  )
  func diffRiskCaptures() async throws {
    let expected: [(String, DiffRiskLevel)] = [
      ("docs", .low), ("thresholds", .medium), ("path-leak", .medium), ("egress", .high),
    ]
    for (name, level) in expected {
      let (judge, transport) = Self.jev([try FakeHTTPTransport.captured("diff-risk-\(name)")])
      let change = try Self.change(name)
      let result = await Self.risk(change, sensitive: []) { subject, questions in
        try await judge.answer(subject, questions: questions)
      }
      #expect(result == .success(.judged(level)), "\(name)")
      let sent = try #require(transport.requests.first)
      #expect(
        try Self.sortedJSON(sent.body)
          == Self.sortedJSON(Fixture.data("Judge/jev-request-diff-risk-\(name).json")), "\(name)")
    }
  }

  @Test(
    "each captured finding-severity reply reads as its severity, from a request equal to its capture — catches the finding's own severity sent to the judge"
  )
  func findingSeverityCaptures() async throws {
    let diff = try Fixture.text("Review/dismiss-without-cancel.patch")
    let expected: [(String, String, Int, Severity)] = [
      ("cancel", "concurrency", 0, .major), ("loading", "test-quality", 1, .minor),
    ]
    for (name, focus, index, severity) in expected {
      let (judge, transport) = Self.jev([
        try FakeHTTPTransport.captured("finding-severity-\(name)")
      ])
      let result = await Self.severity(try Self.finding(focus, index), diff: diff) {
        subject, questions in
        try await judge.answer(subject, questions: questions)
      }
      #expect(result == .success(severity), "\(name)")
      let sent = try #require(transport.requests.first)
      #expect(
        try Self.sortedJSON(sent.body)
          == Self.sortedJSON(Fixture.data("Judge/jev-request-finding-severity-\(name).json")),
        "\(name)")
    }
  }

  static func cascade(jev: [FakeHTTPTransport.Reply], claude: FakeJudge?, base: JudgeQuestionSet)
    -> CascadingJudge
  {
    CascadingJudge(
      jev: Self.jev(jev).0, claude: claude, base: base,
      policy: .init(thresholds: JudgeThresholds(advisory: 0.6, block: 0.9), atReadyTier: true),
      clock: FakeRetryClock())
  }

  @Test(
    "when Jev can't answer, the cascade asks Claude and its answer sets the level — catches a risk question the cascade leaves unasked"
  )
  func jevDownGoesToClaude() async throws {
    let down = FakeHTTPTransport.Reply.failure(.unreachable("connection refused"))
    let claude = FakeJudge.answering(flagged: 0.8)
    let judge = Self.cascade(jev: [down, down], claude: claude, base: .diffRisk)
    let result = await Self.risk(try Self.change("docs"), sensitive: []) {
      subject, questions in
      try await judge.classifyingAnswers(subject, questions: questions)
    }
    #expect(result == .success(.judged(.high)))
    #expect(claude.subjects.count == 1)

    let severityClaude = FakeJudge.answering(flagged: 0.8)
    let severityJudge = Self.cascade(
      jev: [down, down], claude: severityClaude, base: .findingSeverity)
    let severity = await Self.severity(
      try Self.finding("concurrency", 0), diff: ""
    ) { subject, questions in
      try await severityJudge.classifyingAnswers(subject, questions: questions)
    }
    #expect(severity == .success(.blocker))
  }

  @Test(
    "when Jev answers, its level stands and Claude isn't asked — catches every classification paying for Claude"
  )
  func jevAnswerStands() async throws {
    let claude = FakeJudge.answering(flagged: 0.8)
    let judge = Self.cascade(
      jev: [try FakeHTTPTransport.captured("diff-risk-egress")], claude: claude, base: .diffRisk)
    let result = await Self.risk(try Self.change("egress"), sensitive: []) {
      subject, questions in
      try await judge.classifyingAnswers(subject, questions: questions)
    }
    #expect(result == .success(.judged(.high)))
    #expect(claude.subjects.isEmpty)
  }

  @Test(
    "when neither Jev nor Claude answers, the cascade gives an error naming both, never a level — catches a silent low"
  )
  func bothDownIsAnError() async throws {
    let down = FakeHTTPTransport.Reply.failure(.unreachable("connection refused"))
    let judge = Self.cascade(jev: [down, down], claude: nil, base: .diffRisk)
    let result = await Self.risk(try Self.change("docs"), sensitive: []) {
      subject, questions in
      try await judge.classifyingAnswers(subject, questions: questions)
    }
    guard case .failure(.noAnswer(let why)) = result else {
      Issue.record("expected no answer, got \(result)")
      return
    }
    #expect(why.contains("connection refused"))
    #expect(why.contains("no Claude judge is available"))
  }
}

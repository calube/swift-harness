import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

@Suite("judge adapters")
struct JudgeAdaptersTests {
  /// The one-question set the real capture was made with.
  static let captureSet = JudgeQuestionSet(
    id: "capture", version: 1, subjectDescription: "a Swift test",
    questions: [JudgeQuestionSet.tests.questions[0]])

  static let subject = JudgeSubject(
    id: "T.doubles()", file: "Tests/T.swift", line: 3,
    source: "@Test(\"doubling 2 gives 4\") func doubles() { #expect(double(2) == 4) }",
    context: "+ func double(_ x: Int) -> Int { x * 2 }", declaredTier: "T1")

  static func replaying(_ fixture: String, status: Int32) -> FakeProcessRunner {
    FakeProcessRunner { _ throws(ProcessRunnerError) in
      ProcessOutput(
        status: .exited(status), stdout: (try? Fixture.text("Judge/\(fixture)")) ?? "", stderr: "")
    }
  }

  @Test(
    "a real claude result envelope parses into a normalized distribution — catches the judge misreading structured_output"
  )
  func parsesRealResult() throws {
    let answers = try ClaudeJudgeReply.parse(
      Fixture.data("Judge/claude-result.json"), stderr: "", for: Self.captureSet)
    #expect(answers.count == 1)
    #expect(answers[0].question == "fails-if-broken")
    #expect(abs(answers[0].probability(of: "yes") - 0.99) < 1e-9)
    #expect(answers[0].rationale?.isEmpty == false)
  }

  @Test(
    "a real error envelope is a backend error with claude's message — catches an API failure read as an empty answer"
  )
  func parsesRealError() throws {
    #expect {
      try ClaudeJudgeReply.parse(
        Fixture.data("Judge/claude-unknown-model.json"), stderr: "", for: Self.captureSet)
    } throws: { error in
      guard case JudgeError.backend(let message) = error else { return false }
      return message.contains("no-such-model")
    }
  }

  @Test(
    "a reply that omits a question is malformed — catches a partial reply silently skipping a question"
  )
  func missingQuestionIsMalformed() throws {
    #expect(throws: JudgeError.self) {
      try ClaudeJudgeReply.parse(
        Fixture.data("Judge/claude-result.json"), stderr: "", for: JudgeQuestionSet.tests)
    }
  }

  @Test(
    "the schema builder produces exactly the schema the capture was made with — catches the fixture drifting from what the adapter sends"
  )
  func schemaMatchesCapture() throws {
    let built =
      try JSONSerialization.jsonObject(
        with: Data(ClaudeJudgePrompt.schema(for: Self.captureSet).utf8)) as? NSDictionary
    let captured =
      try JSONSerialization.jsonObject(
        with: Fixture.data("Judge/claude-capture-schema.json")) as? NSDictionary
    #expect(built == captured)
  }

  @Test(
    "the claude judge runs claude -p with the schema, no tools or settings, and the subject on stdin — catches the judge running with tools, hooks or a transcript"
  )
  func invocation() async throws {
    let runner = Self.replaying("claude-result.json", status: 0)
    let judge = ClaudeCLIJudge(runner: runner, model: "haiku")

    let answers = try await judge.answer(Self.subject, questions: Self.captureSet)

    #expect(answers.first?.question == "fails-if-broken")
    let call = try #require(runner.invocations.first)
    #expect(call.executable == "claude")
    for flag in [
      "-p", "--restricted", "--strict-mcp-config", "--no-session-persistence", "--json-schema",
    ] {
      #expect(call.arguments.contains(flag))
    }
    let tools = try #require(call.arguments.firstIndex(of: "--tools"))
    #expect(call.arguments[tools + 1] == "")
    let model = try #require(call.arguments.firstIndex(of: "--model"))
    #expect(call.arguments[model + 1] == "haiku")
    let prompt = String(decoding: call.standardInput ?? Data(), as: UTF8.self)
    #expect(prompt.contains(Self.subject.source))
    #expect(prompt.contains(Self.subject.context))
    #expect(prompt.contains("fails-if-broken"))
  }

  @Test(
    "the claude judge pins verbose off through --settings — catches a global verbose config turning the json result into an event array the parser can't read"
  )
  func invocationPinsVerboseOff() async throws {
    let runner = Self.replaying("claude-result.json", status: 0)
    _ = try await ClaudeCLIJudge(runner: runner, model: "haiku")
      .answer(Self.subject, questions: Self.captureSet)

    let call = try #require(runner.invocations.first)
    let settings = try #require(call.arguments.firstIndex(of: "--settings"))
    let object = try #require(
      try JSONSerialization.jsonObject(with: Data(call.arguments[settings + 1].utf8))
        as? [String: Any])
    #expect(object["verbose"] as? Bool == false)
  }

  @Test(
    "the cache answers a repeat question without the backend and misses when the model changes — catches paying twice for a stable test or reusing another model's answers"
  )
  func caching() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "swiftgate-judge-cache-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runner = Self.replaying("claude-result.json", status: 0)
    let cache = FileJudgeCache(directory: directory)

    let sonnet = CachingJudge(ClaudeCLIJudge(runner: runner, model: "sonnet"), cache: cache)
    let first = try await sonnet.answer(Self.subject, questions: Self.captureSet)
    let second = try await sonnet.answer(Self.subject, questions: Self.captureSet)
    #expect(first == second)
    #expect(runner.invocations.count == 1)

    let opus = CachingJudge(ClaudeCLIJudge(runner: runner, model: "opus"), cache: cache)
    _ = try await opus.answer(Self.subject, questions: Self.captureSet)
    #expect(runner.invocations.count == 2)
  }

  @Test(
    "a real claude envelope yields its cost, both durations, token counts and served model — catches usage read from the wrong keys"
  )
  func claudeUsageFromRealResult() throws {
    let reply = try ClaudeJudgeReply.parseReply(
      Fixture.data("Judge/claude-result.json"), stderr: "", for: Self.captureSet)
    let usage = try #require(reply.usage)
    #expect(reply.answers.first?.question == "fails-if-broken")
    #expect(abs((usage.costUSD ?? 0) - 0.01017275) < 1e-12)
    #expect(usage.wallMilliseconds == 8389)
    #expect(usage.backendMilliseconds == 8352)
    #expect(usage.inputTokens == 9 + 4527 + 0)
    #expect(usage.outputTokens == 901)
    #expect(usage.servedModel == "claude-haiku-4-5-20251001")
    #expect(usage.cached == false)
  }

  @Test(
    "an envelope whose modelUsage names 2 models is malformed and names both — catches one answer credited to whichever model sorts first"
  )
  func twoServedModelsAreMalformed() throws {
    var envelope = try #require(
      try JSONSerialization.jsonObject(with: Fixture.data("Judge/claude-result.json"))
        as? [String: Any])
    var models = try #require(envelope["modelUsage"] as? [String: Any])
    models["claude-sonnet-5-5"] = models["claude-haiku-4-5-20251001"]
    envelope["modelUsage"] = models
    let stdout = try JSONSerialization.data(withJSONObject: envelope)

    #expect {
      try ClaudeJudgeReply.parseReply(stdout, stderr: "", for: Self.captureSet)
    } throws: { error in
      guard case JudgeError.malformedReply(let message) = error else { return false }
      return message.contains("claude-haiku-4-5-20251001") && message.contains("claude-sonnet-5-5")
    }
  }

  @Test(
    "an envelope without duration_ms is malformed — catches a reply recorded with no wall time"
  )
  func missingDurationIsMalformed() throws {
    var envelope = try #require(
      try JSONSerialization.jsonObject(with: Fixture.data("Judge/claude-result.json"))
        as? [String: Any])
    envelope["duration_ms"] = nil
    let stdout = try JSONSerialization.data(withJSONObject: envelope)

    #expect {
      try ClaudeJudgeReply.parseReply(stdout, stderr: "", for: Self.captureSet)
    } throws: { error in
      guard case JudgeError.malformedReply(let message) = error else { return false }
      return message.contains("duration_ms")
    }
  }

  @Test(
    "the claude judge's measured answer carries the envelope's usage — catches the live backend dropping its usage"
  )
  func claudeMeasuredAnswer() async throws {
    let runner = Self.replaying("claude-result.json", status: 0)
    let reply = try await ClaudeCLIJudge(runner: runner, model: "haiku")
      .measuredAnswer(Self.subject, questions: Self.captureSet)
    #expect(reply.usage?.servedModel == "claude-haiku-4-5-20251001")
    #expect(abs((reply.usage?.costUSD ?? 0) - 0.01017275) < 1e-12)
    #expect(runner.invocations.count == 1)
  }

  @Test(
    "a cache hit reports cached and 0 cost, and a miss reports the inner judge's usage — catches a cache that bills twice or hides a live call"
  )
  func cachingUsage() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "swiftgate-judge-cache-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runner = Self.replaying("claude-result.json", status: 0)
    let judge = CachingJudge(
      ClaudeCLIJudge(runner: runner, model: "haiku"), cache: FileJudgeCache(directory: directory))

    let miss = try await judge.measuredAnswer(Self.subject, questions: Self.captureSet)
    let missUsage = try #require(miss.usage)
    #expect(missUsage.cached == false)
    #expect(abs((missUsage.costUSD ?? 0) - 0.01017275) < 1e-12)
    #expect(missUsage.servedModel == "claude-haiku-4-5-20251001")

    let hit = try await judge.measuredAnswer(Self.subject, questions: Self.captureSet)
    let hitUsage = try #require(hit.usage)
    #expect(hit.answers == miss.answers)
    #expect(hitUsage.cached == true)
    #expect(hitUsage.costUSD == 0)
    #expect(hitUsage.inputTokens == nil)
    #expect(runner.invocations.count == 1)
  }

  @Test(
    "a judge without its own accounting reports wall time and no tokens or cost — catches a default that invents a cost"
  )
  func defaultUsageHasNoCost() async throws {
    let judge = FakeJudge.answering(flagged: 0.9)
    let reply = try await judge.measuredAnswer(Self.subject, questions: .tests)
    let usage = try #require(reply.usage)
    #expect(reply.answers.count == JudgeQuestionSet.tests.questions.count)
    #expect(usage.inputTokens == nil)
    #expect(usage.outputTokens == nil)
    #expect(usage.costUSD == nil)
    #expect(usage.servedModel == nil)
    #expect(usage.cached == false)
    #expect(usage.wallMilliseconds >= 0)
  }

  @Test(
    "a disabled judge constructs no backend — catches test source leaving the machine in a repository that never opted in"
  )
  func disabledBuildsNothing() {
    let runner = Self.replaying("claude-result.json", status: 0)
    #expect(JudgeFactory.make(.disabled, runner: runner, cacheDirectory: nil) == nil)
    #expect(runner.invocations.isEmpty)
  }

  @Test("the Jev backend reports not configured — catches a stub silently answering nothing")
  func jevIsBlocked() async {
    let judge = JudgeFactory.make(
      .enabled(backend: .jev, thresholds: JudgeThresholds(advisory: 0.6, block: 0.9)),
      runner: Self.replaying("claude-result.json", status: 0), cacheDirectory: nil)
    await #expect {
      _ = try await judge?.answer(Self.subject, questions: .tests)
    } throws: { error in
      guard case JudgeError.notConfigured = error else { return false }
      return (error as? JudgeError)?.verdict == .blocked
    }
  }

  @Test(
    "a recording for another question-set version is refused — catches calibration run against stale answers"
  )
  func recordingVersionChecked() async {
    let judge = RecordedJudge(
      .init(
        questionSet: "test-quality@0", identity: JudgeIdentity(backend: "claude", model: "sonnet"),
        answers: [:]))
    await #expect(throws: JudgeError.self) {
      _ = try await judge.answer(Self.subject, questions: .tests)
    }
  }
}

import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// The calibrate design dataset `judge bench --dataset calibrate-design:<run id>` loads, built from
/// this checkout's real seeds and agents, sent through each backend's request and reply.
@Suite("judge question keys over the calibrate design dataset")
struct JudgeQuestionKeysAdapterTests {
  static let runID = "20260930T120000Z-0000abcd"

  /// What Claude's API accepts as a top-level schema property key.
  static func claudeAccepts(_ key: String) -> Bool {
    key.wholeMatch(of: /[a-zA-Z0-9_.\-]{1,64}/) != nil
  }

  /// The real seeds and agents copied beside a kept reply for every seed, so the loader reads the
  /// questions a live run asks.
  static func dataset() throws -> JudgeDataset {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "judge-keys-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let checkout = Fixture.checkoutRoot.deletingLastPathComponent()
    for path in ["plugin/agents", "plugin/gate/Fixtures/calibrate-design"] {
      try FileManager.default.createDirectory(
        at: root.appending(path: path).deletingLastPathComponent(),
        withIntermediateDirectories: true)
      try FileManager.default.copyItem(
        at: checkout.appending(path: path), to: root.appending(path: path))
    }
    let seeds = DesignCalibrationSeeds.load(root: root)
    let replies = DesignCalibrationReplies(root: root, runID: runID, mode: .replay)
    for agent in seeds.agents {
      for seed in agent.cases {
        let reply = root.appending(path: replies.replyPath(agent: agent.name, seed: seed.name))
        try FileManager.default.createDirectory(
          at: reply.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("## Decision\n".utf8).write(to: reply)
        try Data(
          #"{"schemaVersion": 1, "requestedModel": "opus", "servedModels": ["claude-opus-5-5"]}"#
            .utf8
        ).write(to: root.appending(path: replies.metadataPath(agent: agent.name, seed: seed.name)))
      }
    }
    return try JudgeDatasetLoader.storedReplies(root: root, runID: runID)
  }

  static func subject(_ item: JudgeDatasetCase) -> JudgeSubject {
    JudgeSubject(
      id: item.id, file: "input.md", line: 1, source: item.source, context: item.context)
  }

  /// Each case's expected options, keyed by question id.
  static func expected(_ dataset: JudgeDataset, _ item: JudgeDatasetCase) throws -> [String: String]
  {
    try #require(item.labels[dataset.labelsVersion]?.expected)
  }

  @Test(
    "every question key the calibrate design dataset sends Claude is one its API accepts — catches judge bench failing with a 400 on the first case"
  )
  func claudeSchemaKeysAreAccepted() throws {
    let dataset = try Self.dataset()
    #expect(dataset.cases.count >= 2)

    for item in dataset.cases {
      let schema = try #require(
        try JSONSerialization.jsonObject(
          with: Data(ClaudeJudgePrompt.schema(for: dataset.questions(for: item)).utf8))
          as? [String: Any])
      let keys = try #require(schema["properties"] as? [String: Any]).keys
      let required = try #require(schema["required"] as? [String])
      #expect(Set(keys) == Set(required))
      for key in keys {
        #expect(Self.claudeAccepts(key), "\(item.id) sends `\(key)`")
      }
    }
  }

  @Test(
    "Claude's answers under the sent keys come back under each question's dataset id — catches a benchmark that scores no answer, or the wrong one"
  )
  func claudeAnswersMapBackToIDs() throws {
    let dataset = try Self.dataset()
    let captured = try #require(
      try JSONSerialization.jsonObject(with: Fixture.data("Judge/claude-result.json"))
        as? [String: Any])

    for item in dataset.cases {
      let questions = dataset.questions(for: item)
      let expected = try Self.expected(dataset, item)
      let schema = try #require(
        try JSONSerialization.jsonObject(
          with: Data(ClaudeJudgePrompt.schema(for: questions).utf8)) as? [String: Any])
      let sent = try #require(schema["properties"] as? [String: Any])
      let keys = JudgeQuestionKeys(questions)
      var structured: [String: Any] = [:]
      for question in questions.questions {
        let key = keys.key(for: question.id)
        #expect(sent[key] != nil, "the schema doesn't send `\(key)`")
        var answer: [String: Any] = ["rationale": "from the reply"]
        for option in question.options {
          answer[option] =
            option == expected[question.id] ? 0.9 : 0.1 / Double(question.options.count - 1)
        }
        structured[key] = answer
      }
      var envelope = captured
      envelope["structured_output"] = structured
      let answers = try ClaudeJudgeReply.parse(
        JSONSerialization.data(withJSONObject: envelope), stderr: "", for: questions)

      #expect(answers.map(\.question) == questions.questions.map(\.id))
      for (answer, question) in zip(answers, questions.questions) {
        #expect(answer.mostLikely(among: question.options) == expected[question.id])
      }
      #expect(questions.questions.contains { keys.key(for: $0.id) != $0.id })
    }
  }

  @Test(
    "every question key the calibrate design dataset sends Jev is API-safe, and Jev's answers come back under each question's dataset id — catches a Jev arm answering no question"
  )
  func jevKeysAreSafeAndMapBack() async throws {
    let dataset = try Self.dataset()
    let captured = try #require(
      try JSONSerialization.jsonObject(
        with: Fixture.data("Judge/jev-test-quality.reply.json")) as? [String: Any])
    let capturedChoice = try #require(
      (captured["answers"] as? [String: Any])?["tier"] as? [String: Any])

    for item in dataset.cases {
      let questions = dataset.questions(for: item)
      let expected = try Self.expected(dataset, item)
      let keys = JudgeQuestionKeys(questions)
      var replies: [String: Any] = [:]
      for question in questions.questions {
        var choice = capturedChoice
        let pick = try #require(expected[question.id])
        choice["choice"] = pick
        choice["probabilities"] = Dictionary(
          uniqueKeysWithValues: question.options.map { ($0, $0 == pick ? 1.0 : 0.0) })
        replies[keys.key(for: question.id)] = choice
      }
      var body = captured
      body["answers"] = replies
      let (judge, transport) = JevJudgeTests.judge([
        JevJudgeTests.response(
          200, String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self))
      ])

      let answers = try await judge.answer(Self.subject(item), questions: questions)

      let request = try #require(transport.requests.first)
      let sent = try #require(
        (try JSONSerialization.jsonObject(with: request.body) as? [String: Any])?["questions"]
          as? [String: Any])
      for key in sent.keys {
        #expect(JudgeQuestionKeys.isSafe(key), "\(item.id) sends `\(key)`")
      }
      #expect(answers.map(\.question) == questions.questions.map(\.id))
      for (answer, question) in zip(answers, questions.questions) {
        #expect(answer.mostLikely(among: question.options) == expected[question.id])
      }
    }
  }
}

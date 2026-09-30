import Testing

@testable import SwiftGateDomain

@Suite("Jev-native rendering of the test-quality questions")
struct JevRenderingTests {
  static func native(_ question: String) throws -> JevNativeQuestion {
    try #require(JevRendering.questions(for: .testsJev)?.first { $0.question == question })
  }

  static func combine(_ question: String, _ answers: [String: JevSubAnswer]) throws -> [String:
    Double]
  {
    let asked = try #require(JudgeQuestionSet.testsJev.questions.first { $0.id == question })
    return try JevRendering.combine(try native(question), question: asked, answers: answers)
  }

  static func noul(_ question: String, _ values: [String: Double]) -> [String: JevSubAnswer] {
    Dictionary(
      values.map {
        (JevRendering.key(question: question, sub: $0.key), JevSubAnswer.noul($0.value))
      }, uniquingKeysWith: { first, _ in first })
  }

  static func isClose(_ lhs: [String: Double], _ rhs: [String: Double]) -> Bool {
    lhs.keys.sorted() == rhs.keys.sorted()
      && lhs.allSatisfy { abs($0.value - (rhs[$0.key] ?? .nan)) < 1e-9 }
  }

  // MARK: - The version

  @Test(
    "test-quality@2-jev asks every @1 question field by field, rendered for Jev and based on @1 — catches a changed question hiding behind basedOn"
  )
  func sameQuestionsAsBase() {
    let native = JudgeQuestionSet.testsJev
    let base = JudgeQuestionSet.tests
    #expect(native.versionedID == "test-quality@2-jev")
    #expect(native.rendering == .jev)
    #expect(native.basedOn == "test-quality@1")
    #expect(native.labelsVersion == "test-quality@1")
    #expect(native.subjectDescription == base.subjectDescription)
    #expect(native.questions.map(\.id) == base.questions.map(\.id))
    for (twin, question) in zip(base.questions, native.questions) {
      #expect(question.id == twin.id)
      #expect(question.text == twin.text, "\(twin.id)")
      #expect(question.kind == twin.kind, "\(twin.id)")
      #expect(question.flag == twin.flag, "\(twin.id)")
      #expect(question.mayBlock == twin.mayBlock, "\(twin.id)")
      #expect(question.problem == twin.problem, "\(twin.id)")
      #expect(question.levelDescriptions == twin.levelDescriptions, "\(twin.id)")
    }
    #expect(base.labelsVersion == base.versionedID)
    #expect(JevRendering.questions(for: .tests) == nil)
  }

  @Test(
    "the rendering asks each question's sub-questions under dotted keys, and tier under its own id — catches a sub-question the reply can't be matched to"
  )
  func renderingKeys() throws {
    let rendering = try #require(JevRendering.questions(for: .testsJev))
    #expect(rendering.map(\.question) == JudgeQuestionSet.tests.questions.map(\.id))
    #expect(
      rendering.flatMap(\.answerKeys) == [
        "fails-if-broken.runs-changed-code", "fails-if-broken.checks-named-result", "tier",
        "name-specificity.catches-adds", "asserts-implementation.call-details",
        "asserts-implementation.private-state", "asserts-implementation.log-text",
      ])
    #expect(
      try Self.native("name-specificity").subQuestions.first?.options == [
        "nothing", "condition", "symptom",
      ])
  }

  // MARK: - The template reason

  @Test(
    "each combined answer's reason names the sub-question that set it, its meaning and p, and a question asked as written has none — catches an advisory Jev finding that can't say which signal fired"
  )
  func reasonNamesTheDrivingSubQuestion() throws {
    #expect(
      JevRendering.reason(
        try Self.native("fails-if-broken"),
        answers: Self.noul(
          "fails-if-broken", ["runs-changed-code": 0.9, "checks-named-result": 0.1]))
        == "checks-named-result: The result the name describes is never compared (p=0.90)")
    #expect(
      JevRendering.reason(
        try Self.native("fails-if-broken"),
        answers: Self.noul(
          "fails-if-broken", ["runs-changed-code": 0.2, "checks-named-result": 0.95]))
        == "runs-changed-code: The test never runs the changed lines (p=0.80)")
    #expect(
      JevRendering.reason(
        try Self.native("asserts-implementation"),
        answers: Self.noul(
          "asserts-implementation",
          ["call-details": 0.3, "private-state": 0.1, "log-text": 0.85]))
        == "log-text answered true (p=0.85): Does an entry in `assertions` compare the exact text "
        + "of a log or debug message?")
    #expect(
      JevRendering.reason(
        try Self.native("name-specificity"),
        answers: [
          "name-specificity.catches-adds": .choice([
            "nothing": 0.2, "condition": 0.7, "symptom": 0.1,
          ])
        ])
        == "catches-adds: A specific input, case or area where it goes wrong, but not what "
        + "anyone would see (p=0.70)")
    #expect(
      JevRendering.reason(try Self.native("tier"), answers: ["tier": .choice(["T1": 1])]) == nil)
    #expect(
      JevRendering.reason(
        try Self.native("fails-if-broken"),
        answers: Self.noul("fails-if-broken", ["runs-changed-code": 0.2])) == nil)
  }

  // MARK: - Combination rules

  @Test(
    "fails-if-broken is no when either signal fails: runs-changed-code 0.9 with checks-named-result 0.1 gives p_no 0.9 — catches an AND for an OR"
  )
  func failsIfBrokenIsAnOr() throws {
    let question = "fails-if-broken"
    let oneFails = try Self.combine(
      question, Self.noul(question, ["runs-changed-code": 0.9, "checks-named-result": 0.1]))
    #expect(Self.isClose(oneFails, ["no": 0.9, "yes": 0.1]))
    let otherFails = try Self.combine(
      question, Self.noul(question, ["runs-changed-code": 0.2, "checks-named-result": 0.95]))
    #expect(Self.isClose(otherFails, ["no": 0.8, "yes": 0.2]))
    let bothHold = try Self.combine(
      question, Self.noul(question, ["runs-changed-code": 0.94, "checks-named-result": 0.94]))
    #expect(Self.isClose(bothHold, ["no": 1 - 0.94, "yes": 0.94]))
  }

  @Test(
    "asserts-implementation is yes at the highest of its 3 signals — catches a mean or product diluting 1 strong signal"
  )
  func assertsImplementationIsAnOr() throws {
    let question = "asserts-implementation"
    let answer = try Self.combine(
      question,
      Self.noul(question, ["call-details": 0.1, "private-state": 0.7, "log-text": 0.2]))
    #expect(Self.isClose(answer, ["yes": 0.7, "no": 0.3]))
    let logOnly = try Self.combine(
      question,
      Self.noul(question, ["call-details": 0.01, "private-state": 0.02, "log-text": 0.85]))
    #expect(Self.isClose(logOnly, ["yes": 0.85, "no": 0.15]))
  }

  @Test(
    "name-specificity maps nothing, condition and symptom onto vague, partial and specific — catches a level swap"
  )
  func nameSpecificityMapsOptions() throws {
    let key = JevRendering.key(question: "name-specificity", sub: "catches-adds")
    let symptom = try Self.combine(
      "name-specificity", [key: .choice(["symptom": 0.8, "condition": 0.15, "nothing": 0.05])])
    #expect(Self.isClose(symptom, ["specific": 0.8, "partial": 0.15, "vague": 0.05]))
    let nothing = try Self.combine(
      "name-specificity", [key: .choice(["symptom": 0.0, "condition": 0.1, "nothing": 0.9])])
    #expect(Self.isClose(nothing, ["specific": 0.0, "partial": 0.1, "vague": 0.9]))
  }

  @Test(
    "tier's Choice probabilities are its distribution — catches tier dropped or remapped by the rendering"
  )
  func tierIsAsked() throws {
    let answer = try Self.combine("tier", ["tier": .choice(["T1": 0.7, "T2": 0.2, "T3": 0.1])])
    #expect(answer == ["T1": 0.7, "T2": 0.2, "T3": 0.1])
  }

  @Test(
    "a missing sub-answer or 1 of the wrong type fails naming its key — catches a question combined from a partial reply"
  )
  func missingOrWrongSubAnswerFails() throws {
    let question = "fails-if-broken"
    #expect(throws: JevCombinationError.missing(key: "fails-if-broken.checks-named-result")) {
      _ = try Self.combine(question, Self.noul(question, ["runs-changed-code": 0.9]))
    }
    var wrong = Self.noul(question, ["runs-changed-code": 0.9, "checks-named-result": 0.1])
    wrong["fails-if-broken.checks-named-result"] = .choice(["true": 1])
    #expect(throws: JevCombinationError.wrongType(key: "fails-if-broken.checks-named-result")) {
      _ = try Self.combine(question, wrong)
    }
    #expect(throws: JevCombinationError.wrongType(key: "name-specificity.catches-adds")) {
      _ = try Self.combine("name-specificity", ["name-specificity.catches-adds": .noul(0.5)])
    }
  }

  // MARK: - Level descriptions

  @Test(
    "@1's name-specificity describes each level with the clause its text already holds, in level order — catches descriptions drifting from the question Claude reads"
  )
  func levelDescriptionsComeFromText() throws {
    let question = try #require(
      JudgeQuestionSet.tests.questions.first { $0.id == "name-specificity" })
    let descriptions = try #require(question.levelDescriptions)
    #expect(
      descriptions == [
        "vague: names no symptom or restates the behavior",
        "partial: names an area but not the symptom",
        "specific: names a user- or caller-visible symptom",
      ])
    #expect(descriptions.map { String($0.prefix { $0 != ":" }) } == question.options)
    #expect(descriptions.allSatisfy { question.text.contains($0) })
    let others = JudgeQuestionSet.tests.questions.filter { $0.id != "name-specificity" }
    #expect(others.allSatisfy { $0.levelDescriptions == nil })
  }

  // MARK: - Cache key

  @Test(
    "2 renderings of the same version give different cache keys, and a backend with no rendering keeps today's key — catches stale answers after a rendering change"
  )
  func renderingChangesCacheKey() {
    let subject = JudgeSubject(
      id: "a", file: "A.swift", line: 1, source: "@Test func a() {}", context: "+ a")
    let jev = JudgeIdentity(backend: "jev", model: "jev-1.13.0")
    let bare = JudgeCacheKey.make(
      subject: subject, questions: .tests, identity: jev, renderedQuestions: #"["vague"]"#)
    let described = JudgeCacheKey.make(
      subject: subject, questions: .tests, identity: jev,
      renderedQuestions: #"["vague: names no symptom or restates the behavior"]"#)
    #expect(bare != described)
    #expect(
      JudgeCacheKey.make(
        subject: subject, questions: .tests, identity: jev, renderedQuestions: #"["vague"]"#)
        == bare)
    // Computed outside Swift from the length-prefixed fields with Python's hashlib.
    #expect(
      JudgeCacheKey.make(
        subject: subject, questions: .tests,
        identity: JudgeIdentity(backend: "claude", model: "sonnet"))
        == "90d44361df1da4cb659c9b05046796a849a7765d199443548dc5d05ddee694d2")
  }
}

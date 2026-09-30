import Foundation
import Testing

@testable import SwiftGateDomain

@Suite(
  "judge dataset: 1 shape, a hash over labels and labellers, person-only views, the fixed split")
struct JudgeDatasetTests {
  static let tests = JudgeQuestionSet.tests.versionedID

  static func label(
    _ labeller: JudgeDatasetLabeller = .agent, failsIfBroken: String = "yes"
  ) -> JudgeDatasetLabel {
    JudgeDatasetLabel(
      labeller: labeller,
      expected: [
        "fails-if-broken": failsIfBroken, "tier": "T1", "name-specificity": "specific",
        "asserts-implementation": "no",
      ])
  }

  static func item(
    _ id: String, source: String = "func testA() {}", labels: [String: JudgeDatasetLabel]
  ) -> JudgeDatasetCase {
    JudgeDatasetCase(id: id, source: source, context: "diff", declaredTier: "T1", labels: labels)
  }

  static func dataset(_ cases: [JudgeDatasetCase]) throws -> JudgeDataset {
    try JudgeDataset(id: "test-quality", questionSet: .builtIn(.tests), cases: cases)
  }

  static func json(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object)
  }

  static var inlineSet: [String: Any] {
    [
      "id": "rubric", "version": 1, "subjectDescription": "a transcript slice",
      "questions": [
        [
          "id": "cites-source", "text": "Does the answer cite its source?", "kind": "binary",
          "flag": ["option": "no"],
        ],
        [
          "id": "tone", "text": "How direct is the answer?", "kind": "score",
          "options": ["evasive", "hedged", "direct"], "flag": ["option": "evasive"],
        ],
      ],
    ]
  }

  @Test(
    "changing 1 label, 1 labeller or 1 source changes the hash — catches a hash over sources only")
  func hashCoversLabelsLabellersAndSources() throws {
    let base = try Self.dataset([
      Self.item("case-0", labels: [Self.tests: Self.label()]),
      Self.item("case-2", labels: [Self.tests: Self.label()]),
    ])
    let relabelled = try Self.dataset([
      Self.item("case-0", labels: [Self.tests: Self.label(failsIfBroken: "no")]),
      Self.item("case-2", labels: [Self.tests: Self.label()]),
    ])
    let byPerson = try Self.dataset([
      Self.item("case-0", labels: [Self.tests: Self.label(.person)]),
      Self.item("case-2", labels: [Self.tests: Self.label()]),
    ])
    let edited = try Self.dataset([
      Self.item("case-0", source: "func testB() {}", labels: [Self.tests: Self.label()]),
      Self.item("case-2", labels: [Self.tests: Self.label()]),
    ])

    let hashes = [base.hash, relabelled.hash, byPerson.hash, edited.hash]
    #expect(Set(hashes).count == 4)
    #expect(hashes.allSatisfy { $0.count == 64 && $0.allSatisfy(\.isHexDigit) })
  }

  @Test("the hash doesn't depend on case order — catches a hash over the file as written")
  func hashIgnoresCaseOrder() throws {
    let a = Self.item("case-0", labels: [Self.tests: Self.label()])
    let b = Self.item("case-2", labels: [Self.tests: Self.label(.person)])
    let hash = try Self.dataset([a, b]).hash
    #expect(hash.count == 64)
    #expect(try hash == Self.dataset([b, a]).hash)
  }

  @Test(
    "the canonical JSON decodes back to the same dataset and hash — catches an encoding the decoder can't read"
  )
  func canonicalJSONRoundTrips() throws {
    let data = try Self.json([
      "schemaVersion": 1, "id": "rubric-trial", "inlineQuestionSet": Self.inlineSet,
      "cases": [
        [
          "id": "slice-1", "source": "answer", "context": "question",
          "labels": [
            "rubric@1": [
              "labeller": "person", "expected": ["cites-source": "no", "tone": "direct"],
            ]
          ],
        ]
      ],
    ])
    let dataset = try JudgeDataset.decode(data)
    let again = try JudgeDataset.decode(dataset.canonicalJSON)

    #expect(again == dataset)
    #expect(again.hash == dataset.hash)
    #expect(dataset.questions.versionedID == "rubric@1")
    #expect(
      dataset.questions.questions.map(\.options) == [
        ["yes", "no"], ["evasive", "hedged", "direct"],
      ])
    #expect(dataset.cases.first?.labels["rubric@1"]?.labeller == .person)
  }

  @Test(
    "a built-in question set decodes from its versioned id — catches a dataset that must restate the built-in questions"
  )
  func builtInQuestionSetByID() throws {
    let data = try Self.json([
      "schemaVersion": 1, "id": "comments", "questionSet": "comments@1",
      "cases": [
        [
          "id": "c-1", "source": "// x", "context": "let x = 1",
          "labels": ["comments@1": ["expected": ["loses-fact": "no", "right-size": "yes"]]],
        ]
      ],
    ])
    let dataset = try JudgeDataset.decode(data)

    #expect(dataset.questionSet == .builtIn(.comments))
    // A label without a labeller carries an agent's labels, never a person's.
    #expect(dataset.cases.first?.labels["comments@1"]?.labeller == .agent)
  }

  @Test(
    "a label naming an option its question lacks fails naming both — catches a label the scorer would count as a miss"
  )
  func unknownOptionNamesQuestionAndOption() throws {
    var bad = Self.label().expected
    bad["fails-if-broken"] = "maybe"

    #expect(
      throws: JudgeDatasetError.unknownOption(
        caseID: "case-0", question: "fails-if-broken", option: "maybe", options: ["yes", "no"])
    ) {
      try Self.dataset([
        Self.item(
          "case-0", labels: [Self.tests: JudgeDatasetLabel(labeller: .agent, expected: bad)])
      ])
    }
    let message =
      "\(JudgeDatasetError.unknownOption(caseID: "case-0", question: "fails-if-broken", option: "maybe", options: ["yes", "no"]))"
    #expect(message.contains("fails-if-broken") && message.contains("maybe"))
  }

  @Test(
    "labels for an unknown question, an unknown question set, or a repeated case id fail naming it — catches a typo dropping labels"
  )
  func rejectsUnknownQuestionsSetsAndDuplicates() throws {
    #expect(
      throws: JudgeDatasetError.unknownQuestion(
        caseID: "case-0", questionSet: Self.tests, question: "fails-if-brokn")
    ) {
      try Self.dataset([
        Self.item(
          "case-0",
          labels: [
            Self.tests: JudgeDatasetLabel(labeller: .agent, expected: ["fails-if-brokn": "no"])
          ])
      ])
    }
    #expect(throws: JudgeDatasetError.unknownQuestionSet("test-quality@9")) {
      try Self.dataset([Self.item("case-0", labels: ["test-quality@9": Self.label()])])
    }
    #expect(throws: JudgeDatasetError.duplicateCase("case-0")) {
      try Self.dataset([
        Self.item("case-0", labels: [Self.tests: Self.label()]),
        Self.item("case-0", labels: [Self.tests: Self.label()]),
      ])
    }
  }

  @Test(
    "a dataset JSON with an unknown key or schema version fails — catches a misspelt field read as absent"
  )
  func rejectsUnknownKeysAndSchemas() throws {
    let item: [String: Any] = [
      "id": "c-1", "source": "// x", "context": "", "labeler": "person",
      "labels": ["comments@1": ["expected": ["loses-fact": "no"]]],
    ]
    #expect(throws: JudgeDatasetError.self) {
      try JudgeDataset.decode(
        try Self.json(["schemaVersion": 1, "id": "d", "questionSet": "comments@1", "cases": [item]])
      )
    }
    #expect(throws: JudgeDatasetError.unsupportedSchema(2)) {
      try JudgeDataset.decode(
        try Self.json(["schemaVersion": 2, "id": "d", "questionSet": "comments@1", "cases": []]))
    }
  }

  @Test(
    "an inline question whose flag isn't 1 of its options fails naming the question — catches a flag that never fires"
  )
  func inlineFlagMustBeAnOption() throws {
    var set = Self.inlineSet
    set["questions"] = [
      ["id": "cites-source", "text": "Cites?", "kind": "binary", "flag": ["option": "nope"]]
    ]
    let data = try Self.json(["schemaVersion": 1, "id": "d", "inlineQuestionSet": set, "cases": []])

    #expect {
      try JudgeDataset.decode(data)
    } throws: { error in
      guard case JudgeDatasetError.invalidQuestion(let question, _) = error else { return false }
      return question == "cites-source"
    }
  }

  @Test(
    "the person-only view holds only person labels, and the labeller mix counts each labeller — catches agent labels shown as a person's"
  )
  func personOnlyViewExcludesAgentAndSeedLabels() throws {
    let dataset = try Self.dataset([
      Self.item("case-0", labels: [Self.tests: Self.label(.person, failsIfBroken: "no")]),
      Self.item("case-1", labels: [Self.tests: Self.label(.agent)]),
      Self.item("case-2", labels: [Self.tests: Self.label(.seed)]),
      Self.item("case-4", labels: [:]),
    ])

    #expect(
      dataset.benchmarkCases(.personOnly) == [
        JudgeBenchmarkCase(
          id: "case-0", declaredTier: "T1", expected: Self.label(failsIfBroken: "no").expected)
      ])
    #expect(dataset.benchmarkCases(.all).map(\.id) == ["case-0", "case-1", "case-2"])
    #expect(dataset.summary.labellers == JudgeDatasetLabellerMix(person: 1, agent: 1, seed: 1))
    #expect(dataset.summary.unlabelled == 1)
    #expect(dataset.summary.cases == 4)
    #expect(dataset.summary.questionSet == Self.tests)
    #expect(dataset.summary.hash == dataset.hash)
  }

  @Test(
    "each case's split is JudgeCaseSplit's, and the summary counts them — catches a second split rule"
  )
  func splitComesFromJudgeCaseSplit() throws {
    // case-0, case-1, case-4 report; case-2, case-3 tune (SHA-256 first byte against 0x55).
    let ids = ["case-0", "case-1", "case-2", "case-3", "case-4"]
    let dataset = try Self.dataset(ids.map { Self.item($0, labels: [Self.tests: Self.label()]) })

    #expect(dataset.cases.map(\.split) == ids.map(JudgeCaseSplit.of))
    #expect(dataset.summary.splits == JudgeDatasetSplitCounts(tune: 2, report: 3))
    #expect(
      JudgeReportCases(dataset.benchmarkCases(.all)).cases.map(\.id) == [
        "case-0", "case-1", "case-4",
      ])
  }

  @Test(
    "labels for 2 versions of a question set share 1 case, and the dataset reads its own version's — catches versions overwriting each other"
  )
  func twoVersionsShareCases() throws {
    let data = try Self.json([
      "schemaVersion": 1, "id": "rubric-trial", "inlineQuestionSet": Self.inlineSet,
      "cases": [
        [
          "id": "slice-1", "source": "answer", "context": "question",
          "labels": [
            "rubric@1": ["labeller": "person", "expected": ["cites-source": "no"]],
            "test-quality@1": ["labeller": "agent", "expected": ["fails-if-broken": "yes"]],
          ],
        ]
      ],
    ])
    let dataset = try JudgeDataset.decode(data)

    #expect(dataset.benchmarkCases(.all).map(\.expected) == [["cites-source": "no"]])
    #expect(dataset.benchmarkCases(.personOnly).count == 1)
  }

  @Test(
    "a case is asked only the questions it has labels for — catches a seed asked another seed's questions"
  )
  func questionsForACaseAreItsLabelledOnes() throws {
    let data = try Self.json([
      "schemaVersion": 1, "id": "rubric-trial", "inlineQuestionSet": Self.inlineSet,
      "cases": [
        [
          "id": "slice-1", "source": "answer", "context": "",
          "labels": ["rubric@1": ["labeller": "seed", "expected": ["tone": "hedged"]]],
        ]
      ],
    ])
    let dataset = try JudgeDataset.decode(data)
    let item = try #require(dataset.cases.first)

    #expect(dataset.questions(for: item).questions.map(\.id) == ["tone"])
    #expect(dataset.questions(for: item).versionedID == "rubric@1")
  }
}

import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("judge dataset loader: the built-in set, a directory, a calibrate design run, a JSON file")
struct JudgeDatasetLoaderTests {
  struct TempRoot {
    let root: URL

    init() throws {
      root = TestTemporaryDirectory.root.appending(
        path: "judge-dataset-\(UUID().uuidString)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(_ path: String, _ text: String) throws {
      let url = root.appending(path: path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(text.utf8).write(to: url)
    }
  }

  static let runID = "20260930T120000Z-0000abcd"

  @Test(
    "the built-in set loads every case directory, with labels.json's labels and labellers and no person label it doesn't name — catches agent labels shown as a person's"
  )
  func builtInSetKeepsItsLabelsAndLabellers() throws {
    let directory = Fixture.checkoutRoot.appending(
      path: JudgeDatasetLoader.testQualityDirectory, directoryHint: .isDirectory)
    let raw = try #require(
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: directory.appending(path: "labels.json"))) as? [String: Any])
    let labelled = try #require(raw["cases"] as? [[String: Any]])
    let caseDirectories = try FileManager.default.contentsOfDirectory(
      atPath: directory.appending(path: "cases").path
    ).filter { !$0.hasPrefix(".") }

    let dataset = try JudgeDatasetLoader.testQuality(harnessRoot: Fixture.checkoutRoot)
    let version = JudgeQuestionSet.tests.versionedID

    #expect(dataset.id == "test-quality")
    #expect(dataset.questionSet == .builtIn(.tests))
    #expect(Set(dataset.cases.map(\.id)) == Set(caseDirectories))
    #expect(dataset.summary.cases - dataset.summary.unlabelled == labelled.count)
    for entry in labelled {
      let id = try #require(entry["id"] as? String)
      let item = try #require(dataset.cases.first { $0.id == id })
      let label = try #require(item.labels[version])
      #expect(label.expected == entry["expected"] as? [String: String])
      #expect(label.labeller.rawValue == (entry["labeller"] as? String ?? "agent"))
      #expect(item.declaredTier == entry["declaredTier"] as? String)
      #expect(
        item.source
          == (try String(
            contentsOf: directory.appending(path: "cases/\(id)/Test.swift.txt"), encoding: .utf8)))
      #expect(
        item.context
          == (try String(
            contentsOf: directory.appending(path: "cases/\(id)/Change.diff"), encoding: .utf8)))
    }
    let people = labelled.filter { $0["labeller"] as? String == "person" }.count
    #expect(dataset.benchmarkCases(.personOnly).count == people)
    #expect(dataset.summary.labellers.person == people)
  }

  @Test(
    "a labels.json case with no labeller loads as an agent's — catches a missing labeller read as a person"
  )
  func missingLabellerIsAgent() throws {
    let repository = try TempRoot()
    try repository.write(
      "set/labels.json",
      """
      {"schema": 1, "questionSet": "test-quality@1", "cases": [
        {"id": "a", "label": "good", "declaredTier": "T1",
         "expected": {"fails-if-broken": "yes"}}]}
      """)
    try repository.write("set/cases/a/Test.swift.txt", "func testA() {}\n")
    try repository.write("set/cases/a/Change.diff", "+let a = 1\n")

    let dataset = try JudgeDatasetLoader.directory(
      repository.root.appending(path: "set", directoryHint: .isDirectory), id: "set")

    #expect(dataset.cases.first?.labels["test-quality@1"]?.labeller == .agent)
    #expect(dataset.benchmarkCases(.personOnly).isEmpty)
    #expect(dataset.benchmarkCases(.all).count == 1)
  }

  @Test(
    "a labelled case with no directory fails naming its path — catches labels scored without a subject"
  )
  func labelledCaseWithoutDirectoryFails() throws {
    let repository = try TempRoot()
    try repository.write(
      "set/labels.json",
      """
      {"schema": 1, "questionSet": "test-quality@1", "cases": [
        {"id": "gone", "label": "good", "declaredTier": "T1", "labeller": "person",
         "expected": {"fails-if-broken": "yes"}}]}
      """)
    try repository.write("set/cases/other/Test.swift.txt", "func testOther() {}\n")
    try repository.write("set/cases/other/Change.diff", "+let other = 1\n")

    #expect {
      try JudgeDatasetLoader.directory(
        repository.root.appending(path: "set", directoryHint: .isDirectory), id: "set")
    } throws: { error in
      "\(error)".contains("cases/gone/Test.swift.txt")
    }
  }

  static func seed(_ repository: TempRoot) throws {
    try repository.write(
      "plugin/agents/design-drafter.md",
      "---\nname: design-drafter\nmodel: opus\n---\n\nYou draft designs.\n")
    try repository.write(
      "plugin/gate/Fixtures/calibrate-design/design-drafter/supported-claim/input.md",
      "Case: draft the sync interval.\n")
    try repository.write(
      "plugin/gate/Fixtures/calibrate-design/design-drafter/supported-claim/label.json",
      """
      {"schemaVersion": 2, "checks": [{"id": "interval-tag", "kind": "judge",
        "text": "What tag does the interval bullet carry?",
        "options": ["a claim id", "the UNVERIFIED tag", "no tag"], "expected": "a claim id"}]}
      """)
  }

  @Test(
    "a calibrate design run's kept replies load as seed-labelled cases, asked only their own questions — catches seed labels shown as a person's"
  )
  func storedRepliesLoadAsSeedLabelledCases() throws {
    let repository = try TempRoot()
    try Self.seed(repository)
    let replies = ".harness/runs/\(Self.runID)/calibrate-design/design-drafter"
    try repository.write("\(replies)/supported-claim.txt", "## Decision\n- every 15 min [ev-3]\n")
    try repository.write(
      "\(replies)/supported-claim.json",
      #"{"schemaVersion": 1, "requestedModel": "opus", "servedModels": ["claude-opus-5-5"]}"#)

    let dataset = try JudgeDatasetLoader.storedReplies(root: repository.root, runID: Self.runID)
    let item = try #require(dataset.cases.first)
    let questions = dataset.questions(for: item)

    #expect(dataset.cases.count == 1)
    #expect(item.id == "design-drafter/supported-claim")
    #expect(item.source == "## Decision\n- every 15 min [ev-3]\n")
    #expect(item.declaredTier == nil)
    #expect(item.labels[dataset.questions.versionedID]?.labeller == .seed)
    #expect(questions.questions.map(\.options) == [["a claim id", "the UNVERIFIED tag", "no tag"]])
    #expect(
      dataset.benchmarkCases(.all).map(\.expected)
        == [[try #require(questions.questions.first).id: "a claim id"]])
    #expect(dataset.benchmarkCases(.personOnly).isEmpty)
  }

  @Test(
    "a run missing a seed's kept reply fails naming the seed — catches a dataset silently short of a seed"
  )
  func storedRepliesMissingReplyNamesTheSeed() throws {
    let repository = try TempRoot()
    try Self.seed(repository)

    #expect {
      try JudgeDatasetLoader.storedReplies(root: repository.root, runID: Self.runID)
    } throws: { error in
      guard case JudgeDatasetError.missingReply(let agent, let seed, let path) = error else {
        return false
      }
      return agent == "design-drafter" && seed == "supported-claim"
        && path.hasSuffix("design-drafter/supported-claim.txt")
        && "\(error)".contains("supported-claim")
    }
  }

  @Test(
    "a dataset JSON file with an option its question lacks fails naming the file, question and option — catches a bad label loaded"
  )
  func fileWithUnknownOptionFailsNamingBoth() throws {
    let repository = try TempRoot()
    try repository.write(
      "rubric.json",
      """
      {"schemaVersion": 1, "id": "rubric", "questionSet": "comments@1", "cases": [
        {"id": "c-1", "source": "// x", "context": "", "labels": {
          "comments@1": {"labeller": "person", "expected": {"loses-fact": "perhaps"}}}}]}
      """)

    #expect {
      try JudgeDatasetLoader.file(repository.root.appending(path: "rubric.json"))
    } throws: { error in
      let message = "\(error)"
      return message.contains("rubric.json") && message.contains("loses-fact")
        && message.contains("perhaps")
    }
  }

  @Test(
    "a dataset JSON file loads to the same dataset its canonical JSON decodes to — catches a file loader that drops fields"
  )
  func fileLoadsTheDataset() throws {
    let repository = try TempRoot()
    try repository.write(
      "rubric.json",
      """
      {"schemaVersion": 1, "id": "rubric", "questionSet": "comments@1", "cases": [
        {"id": "c-1", "source": "// x", "context": "let x = 1", "labels": {
          "comments@1": {"labeller": "person", "expected": {"loses-fact": "no"}}}}]}
      """)

    let dataset = try JudgeDatasetLoader.file(repository.root.appending(path: "rubric.json"))

    #expect(dataset.id == "rubric")
    #expect(dataset.cases.first?.context == "let x = 1")
    #expect(dataset.benchmarkCases(.personOnly).map(\.expected) == [["loses-fact": "no"]])
  }
}

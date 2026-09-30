import Foundation
import SwiftGateDomain

/// Reads a `JudgeDataset` from each place one lives (spec §10.2).
public enum JudgeDatasetLoader {
  public static let testQualityID = "test-quality"
  /// The built-in test-quality set, relative to the harness root.
  public static let testQualityDirectory = "gate/Fixtures/judge"
  public static let labelsFile = "labels.json"
  public static let casesDirectory = "cases"
  public static let sourceFile = "Test.swift.txt"
  public static let contextFile = "Change.diff"
  public static let storedRepliesQuestionSetID = "calibrate-design"
  /// The `schema` a directory's `labels.json` carries.
  public static let directorySchema = 1

  /// The built-in test-quality set under `gate/Fixtures/judge/`.
  public static func testQuality(harnessRoot: URL) throws(JudgeDatasetError) -> JudgeDataset {
    try directory(
      harnessRoot.appending(path: testQualityDirectory, directoryHint: .isDirectory),
      id: testQualityID)
  }

  /// A directory in the built-in set's layout: `labels.json` naming a built-in question set, and
  /// `cases/<id>/` holding `Test.swift.txt` (the source) and `Change.diff` (the context). A case
  /// directory `labels.json` doesn't name loads unlabelled; a labelled case with no directory fails.
  public static func directory(_ url: URL, id: String) throws(JudgeDatasetError) -> JudgeDataset {
    let labelsURL = url.appending(path: labelsFile)
    let labels: DirectoryLabels
    do {
      let data = try Data(contentsOf: labelsURL)
      try DirectoryLabels.checkKeys(try JSONSerialization.jsonObject(with: data))
      labels = try JSONDecoder().decode(DirectoryLabels.self, from: data)
    } catch let error as JudgeDatasetError {
      throw .at(path: labelsURL.path, error)
    } catch {
      throw .unreadable(path: labelsURL.path, reason: "\(error)")
    }
    if let schema = labels.schema, schema != directorySchema {
      throw .at(path: labelsURL.path, .unsupportedSchema(schema))
    }
    guard let questions = JudgeDataset.builtIn(labels.questionSet) else {
      throw .at(path: labelsURL.path, .unknownQuestionSet(labels.questionSet))
    }
    let casesURL = url.appending(path: casesDirectory, directoryHint: .isDirectory)
    let directories: [String]
    do {
      directories = try FileManager.default.contentsOfDirectory(atPath: casesURL.path).filter {
        name in
        var isDirectory: ObjCBool = false
        return !name.hasPrefix(".")
          && FileManager.default.fileExists(
            atPath: casesURL.appending(path: name).path, isDirectory: &isDirectory)
          && isDirectory.boolValue
      }.sorted()
    } catch {
      throw .unreadable(path: casesURL.path, reason: "\(error)")
    }
    let labelled = Set(labels.cases.map(\.id))
    var cases: [JudgeDatasetCase] = []
    for entry in labels.cases {
      cases.append(
        try subject(
          in: casesURL, id: entry.id, declaredTier: entry.declaredTier,
          labels: [
            questions.versionedID: JudgeDatasetLabel(
              // A case without a labeller carries the tuning agent's labels.
              labeller: entry.labeller.map(JudgeDatasetLabeller.init) ?? .agent,
              expected: entry.expected)
          ]))
    }
    for name in directories where !labelled.contains(name) {
      cases.append(try subject(in: casesURL, id: name, declaredTier: nil, labels: [:]))
    }
    do {
      return try JudgeDataset(id: id, questionSet: .builtIn(questions), cases: cases)
    } catch {
      throw .at(path: labelsURL.path, error)
    }
  }

  private static func subject(
    in casesURL: URL, id: String, declaredTier: String?, labels: [String: JudgeDatasetLabel]
  ) throws(JudgeDatasetError) -> JudgeDatasetCase {
    let directory = casesURL.appending(path: id, directoryHint: .isDirectory)
    func text(_ name: String) throws(JudgeDatasetError) -> String {
      let file = directory.appending(path: name)
      do {
        return try String(contentsOf: file, encoding: .utf8)
      } catch {
        throw .unreadable(path: file.path, reason: "\(error)")
      }
    }
    return JudgeDatasetCase(
      id: id, source: try text(sourceFile), context: try text(contextFile),
      declaredTier: declaredTier, labels: labels)
  }

  /// A `calibrate design` run's kept replies, each labelled by its seed's expected options. Only
  /// seeds with judged questions become cases, and each question's id is prefixed with
  /// `<agent>/<seed>/`, so 2 seeds' questions never merge.
  public static func storedReplies(root: URL, runID: String) throws(JudgeDatasetError)
    -> JudgeDataset
  {
    let seeds = DesignCalibrationSeeds.load(root: root)
    guard seeds.problems.isEmpty else {
      throw .invalidSeeds(reason: seeds.problems.map { "\($0)" }.joined(separator: "; "))
    }
    let replies = DesignCalibrationReplies(root: root, runID: runID, mode: .replay)
    var questions: [JudgeQuestion] = []
    var cases: [JudgeDatasetCase] = []
    let version = JudgeQuestionSet(
      id: storedRepliesQuestionSetID, version: CalibrationLabel.currentSchemaVersion,
      subjectDescription: DesignCalibrationRunner.judgeSubjectDescription, questions: []
    ).versionedID
    for agent in seeds.agents {
      for seed in agent.cases {
        let judged = seed.label.judgeQuestions
        guard !judged.isEmpty else { continue }
        let prefix = "\(agent.name)/\(seed.name)/"
        let seedQuestions = DesignCalibrationRunner.judgeQuestionSet(
          agent: agent.name, seed: seed.name, judged
        ).questions
        questions += seedQuestions.map { question in
          JudgeQuestion(
            id: prefix + question.id, text: question.text, kind: question.kind,
            flag: question.flag, mayBlock: question.mayBlock, problem: question.problem)
        }
        let replyPath = replies.replyPath(agent: agent.name, seed: seed.name)
        guard
          FileManager.default.fileExists(
            atPath: root.appending(path: replyPath, directoryHint: .notDirectory).path)
        else {
          throw .missingReply(agent: agent.name, seed: seed.name, path: replyPath)
        }
        let stored: DesignCalibrationReplies.Stored
        do {
          stored = try replies.stored(agent: agent.name, seed: seed.name)
        } catch {
          throw .unreadable(path: replyPath, reason: "\(error)")
        }
        cases.append(
          JudgeDatasetCase(
            id: "\(agent.name)/\(seed.name)", source: stored.reply, context: "",
            declaredTier: nil,
            labels: [
              version: JudgeDatasetLabel(
                labeller: .seed,
                expected: Dictionary(
                  uniqueKeysWithValues: judged.map { (prefix + $0.id, $0.question.expected) }))
            ]))
      }
    }
    return try JudgeDataset(
      id: "\(storedRepliesQuestionSetID):\(runID)",
      questionSet: .inline(
        JudgeQuestionSet(
          id: storedRepliesQuestionSetID, version: CalibrationLabel.currentSchemaVersion,
          subjectDescription: DesignCalibrationRunner.judgeSubjectDescription,
          questions: questions)),
      cases: cases)
  }

  /// A dataset JSON file.
  public static func file(_ url: URL) throws(JudgeDatasetError) -> JudgeDataset {
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw .unreadable(path: url.path, reason: "\(error)")
    }
    do {
      return try JudgeDataset.decode(data)
    } catch {
      throw .at(path: url.path, error)
    }
  }
}

/// `labels.json` in the built-in set's layout.
private struct DirectoryLabels: Decodable {
  struct Case: Decodable {
    let id: String
    let label: JudgeCalibrationSet.Case.Label?
    let declaredTier: String?
    let expected: [String: String]
    let labeller: JudgeCalibrationSet.Case.Labeller?
  }

  let schema: Int?
  let questionSet: String
  let cases: [Case]

  static let topKeys: Set = ["schema", "questionSet", "cases"]
  static let caseKeys: Set = ["id", "label", "declaredTier", "expected", "labeller"]

  /// A misspelt `labeller` must fail, not read as absent and so as an agent's.
  static func checkKeys(_ object: Any) throws(JudgeDatasetError) {
    guard let top = object as? [String: Any] else {
      throw .malformed(reason: "labels.json isn't an object")
    }
    if let unknown = top.keys.sorted().first(where: { !topKeys.contains($0) }) {
      throw .malformed(reason: "labels.json has unknown key `\(unknown)`")
    }
    for (index, entry) in (top["cases"] as? [Any] ?? []).enumerated() {
      guard let fields = entry as? [String: Any] else {
        throw .malformed(reason: "cases[\(index)] isn't an object")
      }
      if let unknown = fields.keys.sorted().first(where: { !caseKeys.contains($0) }) {
        throw .malformed(reason: "cases[\(index)] has unknown key `\(unknown)`")
      }
    }
  }
}

extension JudgeDatasetLabeller {
  init(_ labeller: JudgeCalibrationSet.Case.Labeller) {
    switch labeller {
    case .person: self = .person
    case .agent: self = .agent
    }
  }
}

import CryptoKit
import Foundation

/// Who chose a case's labels. Only `person` labels count toward a person-only benchmark or a
/// block calibration; `seed` labels come from a calibration seed's expected option.
public enum JudgeDatasetLabeller: String, Sendable, Equatable, Codable, CaseIterable {
  case person
  case agent
  case seed
}

/// Which labels a benchmark view reads.
public enum JudgeDatasetLabels: Sendable, Equatable {
  case personOnly
  case all
}

/// One case's labels for one question set version.
public struct JudgeDatasetLabel: Sendable, Equatable {
  public let labeller: JudgeDatasetLabeller
  /// Question id → the option a correct judge picks.
  public let expected: [String: String]

  public init(labeller: JudgeDatasetLabeller, expected: [String: String]) {
    self.labeller = labeller
    self.expected = expected
  }
}

public struct JudgeDatasetCase: Sendable, Equatable {
  public let id: String
  public let source: String
  public let context: String
  /// `nil` for a subject with no tier, such as a comment or an agent's reply.
  public let declaredTier: String?
  /// Versioned question set id (`test-quality@1`) → the case's labels for that set, so 2 versions
  /// of a question set share the same cases.
  public let labels: [String: JudgeDatasetLabel]

  public init(
    id: String, source: String, context: String, declaredTier: String?,
    labels: [String: JudgeDatasetLabel]
  ) {
    self.id = id
    self.source = source
    self.context = context
    self.declaredTier = declaredTier
    self.labels = labels
  }

  public var split: JudgeCaseSplit { JudgeCaseSplit.of(id) }
}

/// A dataset's question set: a built-in set named by its versioned id, or one written inline.
public enum JudgeDatasetQuestionSet: Sendable, Equatable {
  case builtIn(JudgeQuestionSet)
  case inline(JudgeQuestionSet)
}

public enum JudgeDatasetError: Error, Sendable, Equatable {
  case malformed(reason: String)
  case unsupportedSchema(Int)
  case unknownQuestionSet(String)
  case invalidQuestion(question: String, reason: String)
  case duplicateCase(String)
  case unknownQuestion(caseID: String, questionSet: String, question: String)
  case unknownOption(caseID: String, question: String, option: String, options: [String])
  case unreadable(path: String, reason: String)
  case missingReply(agent: String, seed: String, path: String)
  case invalidSeeds(reason: String)
  indirect case at(path: String, JudgeDatasetError)
}

extension JudgeDatasetError: CustomStringConvertible {
  public var description: String { "" }
}

public struct JudgeDatasetSplitCounts: Sendable, Equatable, Codable {
  public let tune: Int
  public let report: Int
}

public struct JudgeDatasetLabellerMix: Sendable, Equatable, Codable {
  public let person: Int
  public let agent: Int
  public let seed: Int
}

/// What a benchmark result records about the dataset it ran on.
public struct JudgeDatasetSummary: Sendable, Equatable, Codable {
  public let id: String
  public let questionSet: String
  public let hash: String
  public let cases: Int
  /// Cases with no labels for the dataset's question set; the benchmark can't score them.
  public let unlabelled: Int
  /// Over the labelled cases.
  public let splits: JudgeDatasetSplitCounts
  public let labellers: JudgeDatasetLabellerMix
}

/// A labelled set a judge backend is measured on (spec §10.2).
public struct JudgeDataset: Sendable, Equatable {
  public static let schemaVersion = 1
  public static let builtInQuestionSets: [JudgeQuestionSet] = [.tests, .comments]

  public let id: String
  public let questionSet: JudgeDatasetQuestionSet
  public let cases: [JudgeDatasetCase]

  public init(id: String, questionSet: JudgeDatasetQuestionSet, cases: [JudgeDatasetCase])
    throws(JudgeDatasetError)
  {
    self.id = id
    self.questionSet = questionSet
    self.cases = cases
  }

  public static func decode(_ data: Data) throws(JudgeDatasetError) -> JudgeDataset {
    throw .malformed(reason: "")
  }

  public var questions: JudgeQuestionSet {
    switch questionSet {
    case .builtIn(let set), .inline(let set): set
    }
  }

  public var canonicalJSON: Data { Data() }

  public var hash: String { "" }

  public func benchmarkCases(_ labels: JudgeDatasetLabels) -> [JudgeBenchmarkCase] { [] }

  public func questions(for item: JudgeDatasetCase) -> JudgeQuestionSet { questions }

  public var summary: JudgeDatasetSummary {
    JudgeDatasetSummary(
      id: id, questionSet: "", hash: hash, cases: 0, unlabelled: 0,
      splits: .init(tune: 0, report: 0), labellers: .init(person: 0, agent: 0, seed: 0))
  }
}

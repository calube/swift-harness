import Foundation

/// 1 arm of a benchmark (design §10.6): a backend at a pinned model, asking a question set.
public struct JudgeBenchmarkArm: Sendable, Hashable, CustomStringConvertible {
  public let backend: JudgeBackend
  public let model: String
  /// A built-in set's versioned id, written after `#`; `nil` asks the dataset's own set.
  public let questionSet: String?

  public init(backend: JudgeBackend, model: String, questionSet: String? = nil) {
    self.backend = backend
    self.model = model
    self.questionSet = questionSet
  }

  /// The built-in sets an arm may name after `#`.
  public static let questionSets: [JudgeQuestionSet] = [.tests, .testsJev, .comments]

  /// `<backend>:<model>` or `<backend>:<model>#<set id>@<version>`.
  public static func parse(_ text: String) throws(JudgeBenchmarkArmError) -> JudgeBenchmarkArm {
    JudgeBenchmarkArm(backend: .claude, model: "")
  }

  public var description: String { "" }

  /// The set this arm asks on `dataset`. It must read the dataset's labels, and a set rendered
  /// for 1 backend is asked only of that backend.
  public func questions(for dataset: JudgeDataset) throws(JudgeBenchmarkArmError)
    -> JudgeQuestionSet
  {
    JudgeQuestionSet(id: "", version: 0, subjectDescription: "", questions: [])
  }

  /// `set` cut to the questions `item` is labelled on under `labelsVersion`, keeping the set's
  /// rendering and base, so a rendered set is still asked as rendered.
  public static func questions(
    _ set: JudgeQuestionSet, for item: JudgeDatasetCase, labelsVersion: String
  ) -> JudgeQuestionSet {
    set
  }
}

public enum JudgeBenchmarkArmError: Error, Sendable, Equatable, CustomStringConvertible {
  /// Not `<backend>:<model>[#<set>]`.
  case malformed(String)
  case unknownBackend(arm: String, backend: String)
  /// A moving alias, such as `sonnet` or `jev-latest`, where the benchmark needs a pinned id.
  case notPinned(arm: String, model: String)
  case unknownQuestionSet(arm: String, questionSet: String, known: [String])
  /// The set reads other labels than the dataset carries.
  case otherLabels(arm: String, questionSet: String, labels: String, dataset: String)
  /// A set rendered for 1 backend, asked of another.
  case renderedForOtherBackend(arm: String, questionSet: String, rendering: String)

  public var description: String { "" }
}

/// Why a benchmark ran: a measurement, or a smoke run of a few cases that proves the path works.
public enum JudgeBenchmarkPurpose: String, Sendable, Equatable, Codable {
  case benchmark
  case smoke
}

/// Which labels a view of the metrics reads.
public enum JudgeBenchmarkLabels: String, Sendable, Equatable, Codable, CaseIterable {
  /// Only a person's labels.
  case person
  /// Every label: a person's, an agent's and a seed's.
  case all
}

/// The backend, the model the run asked for, and the model that answered.
public struct JudgeBenchmarkIdentity: Sendable, Equatable, Codable {
  public let backend: String
  public let requestedModel: String
  /// The model every reply named; `nil` when no reply named one.
  public let servedModel: String?

  public init(backend: String, requestedModel: String, servedModel: String?) {
    self.backend = backend
    self.requestedModel = requestedModel
    self.servedModel = servedModel
  }
}

/// 1 question of the labels' set, as much of it as scoring reads.
public struct JudgeBenchmarkQuestion: Sendable, Equatable, Codable {
  public enum Kind: String, Sendable, Equatable, Codable {
    case binary, choice, score
  }

  public let id: String
  public let kind: Kind
  /// `nil` for a binary question, whose options are yes and no.
  public let options: [String]?
  /// The option that marks a problem; `nil` for a question that flags any tier but the declared one.
  public let flaggedOption: String?

  public init(_ question: JudgeQuestion) {
    id = ""
    kind = .binary
    options = nil
    flaggedOption = nil
  }

  public var question: JudgeQuestion {
    JudgeQuestion(
      id: id, text: "", kind: .binary, flag: .notDeclaredTier, mayBlock: false, problem: "")
  }
}

/// A labelled case as the benchmark recorded it: who labelled it and what they chose.
public struct JudgeBenchmarkLabelledCase: Sendable, Equatable, Codable {
  public let id: String
  public let labeller: JudgeDatasetLabeller
  public let declaredTier: String?
  public let expected: [String: String]

  public init(
    id: String, labeller: JudgeDatasetLabeller, declaredTier: String?, expected: [String: String]
  ) {
    self.id = id
    self.labeller = labeller
    self.declaredTier = declaredTier
    self.expected = expected
  }

  public var benchmarkCase: JudgeBenchmarkCase {
    JudgeBenchmarkCase(id: id, declaredTier: declaredTier, expected: expected)
  }
}

/// 1 request's raw answers and usage.
public struct JudgeBenchmarkReply: Sendable, Equatable, Codable {
  public let answers: [JudgeAnswer]
  public let usage: JudgeUsage?

  public init(_ reply: JudgeReply) {
    answers = []
    usage = nil
  }

  public var reply: JudgeReply { JudgeReply(answers: answers, usage: usage) }
}

/// 1 arm's raw answers: per repeat, case id → the requests that answered it once.
public struct JudgeBenchmarkArmResult: Sendable, Equatable, Codable {
  /// The arm as written on the command line.
  public let arm: String
  public let identity: JudgeBenchmarkIdentity
  /// The versioned set the arm asked.
  public let questionSet: String
  /// The versioned set whose labels score it.
  public let labelsVersion: String
  public let repeats: [[String: [JudgeBenchmarkReply]]]

  public init(
    arm: String, identity: JudgeBenchmarkIdentity, questionSet: String, labelsVersion: String,
    repeats: [[String: [JudgeBenchmarkReply]]]
  ) {
    self.arm = arm
    self.identity = identity
    self.questionSet = questionSet
    self.labelsVersion = labelsVersion
    self.repeats = repeats
  }

  public var run: JudgeBenchmarkRun {
    JudgeBenchmarkRun(identity: JudgeIdentity(backend: "", model: ""), repeats: [])
  }
}

/// 1 arm's numbers in 1 view.
public struct JudgeBenchmarkArmMetrics: Sendable, Equatable, Codable {
  public let arm: String
  public let questions: [JudgeQuestionBenchmark]
  public let usage: JudgeUsageBenchmark
}

/// 2 arms compared on every question, first minus second.
public struct JudgeBenchmarkPairMetrics: Sendable, Equatable, Codable {
  public let first: String
  public let second: String
  public let questions: [JudgeBackendComparison]
}

/// The metrics over 1 kind of label.
public struct JudgeBenchmarkView: Sendable, Equatable, Codable {
  public enum Outcome: Sendable, Equatable, Codable {
    case measured(arms: [JudgeBenchmarkArmMetrics], pairs: [JudgeBenchmarkPairMetrics])
    /// No case carries a label of this kind, so the view reports nothing rather than another
    /// kind's numbers.
    case noLabels
  }

  public let labels: JudgeBenchmarkLabels
  /// Labelled cases of this kind in the report split.
  public let reportCases: Int
  public let outcome: Outcome
}

public struct JudgeBenchmarkMetricsSection: Sendable, Equatable, Codable {
  /// `person`, then `all`.
  public let views: [JudgeBenchmarkView]
}

public enum JudgeBenchmarkReportError: Error, Sendable, Equatable, CustomStringConvertible {
  case malformed(String)
  case unsupportedSchema(Int)
  /// The stored metrics differ from those the raw answers give, at each named place.
  case metricsDiffer([String])

  public var description: String { "" }
}

/// `swiftgate judge bench`'s versioned result (design §10.6): the raw answers and the metrics
/// computed from them.
public struct JudgeBenchmarkReport: Sendable, Equatable, Codable {
  public static let schemaVersion = 1

  public let schemaVersion: Int
  public let swiftgateVersion: String
  /// ISO 8601, UTC.
  public let startedAt: String
  public let purpose: JudgeBenchmarkPurpose
  public let dataset: JudgeDatasetSummary
  /// The labels' question set, as scoring reads it.
  public let questions: [JudgeBenchmarkQuestion]
  public let cases: [JudgeBenchmarkLabelledCase]
  public let threshold: Double
  public let repeats: Int
  public let arms: [JudgeBenchmarkArmResult]
  public let metrics: JudgeBenchmarkMetricsSection

  /// Computes `metrics` from the raw answers.
  public init(
    swiftgateVersion: String, startedAt: String, purpose: JudgeBenchmarkPurpose,
    dataset: JudgeDatasetSummary, questions: [JudgeQuestion], cases: [JudgeBenchmarkLabelledCase],
    threshold: Double, repeats: Int, arms: [JudgeBenchmarkArmResult]
  ) {
    schemaVersion = Self.schemaVersion
    self.swiftgateVersion = swiftgateVersion
    self.startedAt = startedAt
    self.purpose = purpose
    self.dataset = dataset
    self.questions = questions.map(JudgeBenchmarkQuestion.init)
    self.cases = cases
    self.threshold = threshold
    self.repeats = repeats
    self.arms = arms
    metrics = JudgeBenchmarkMetricsSection(views: [])
  }

  /// Every view's metrics from the raw answers, by ``JudgeBenchmarkMetrics``.
  public static func metrics(
    questions: [JudgeQuestion], cases: [JudgeBenchmarkLabelledCase],
    arms: [JudgeBenchmarkArmResult], threshold: Double
  ) -> JudgeBenchmarkMetricsSection {
    JudgeBenchmarkMetricsSection(views: [])
  }

  /// Rejects a key this version doesn't write, and a schema it doesn't read.
  public static func decode(_ data: Data) throws(JudgeBenchmarkReportError) -> JudgeBenchmarkReport
  {
    throw .malformed("")
  }

  /// Sorted keys, so the same result always has the same bytes.
  public var json: Data { Data() }

  /// Recomputes the metrics and throws naming each place the stored ones differ.
  public func verify() throws(JudgeBenchmarkReportError) {}

  /// The comparison page: per view and question, every arm side by side.
  public var markdown: String { "" }
}

/// What a set of arms would cost before any call, from usage a past run recorded.
public struct JudgeBenchmarkEstimate: Sendable, Equatable {
  /// Usage recorded for 1 backend and model.
  public struct Recorded: Sendable, Equatable {
    public let backend: String
    public let model: String
    public let usages: [JudgeUsage]
    /// The file it came from, for the estimate to name.
    public let source: String

    public init(backend: String, model: String, usages: [JudgeUsage], source: String) {
      self.backend = backend
      self.model = model
      self.usages = usages
      self.source = source
    }
  }

  public enum Basis: Sendable, Equatable {
    /// The mean cost of `calls` recorded, uncached calls at the arm's model.
    case recorded(meanPerCall: Double, calls: Int, sources: [String])
    case noRecordedUsage
  }

  public struct Arm: Sendable, Equatable {
    public let arm: String
    public let backend: JudgeBackend
    public let calls: Int
    public let judgments: Int
    public let costUSD: Double?
    public let basis: Basis
  }

  public let arms: [Arm]

  /// `judgments[i]` is the questions case `i` is asked; each arm asks every case once per repeat.
  public static func make(
    arms: [JudgeBenchmarkArm], judgments: [Int], repeats: Int, recorded: [Recorded]
  ) -> JudgeBenchmarkEstimate {
    JudgeBenchmarkEstimate(arms: [])
  }

  /// Every usage a bench result or a judge recording holds, by backend and model.
  public static func recorded(from data: Data, source: String) throws(JudgeBenchmarkReportError)
    -> [Recorded]
  {
    []
  }

  /// The Claude spend, or `nil` when a Claude arm has no recorded usage to estimate from.
  public var claudeCostUSD: Double? { nil }

  public var text: String { "" }
}

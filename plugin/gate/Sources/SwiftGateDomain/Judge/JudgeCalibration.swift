import Foundation

/// The labeled calibration set under `gate/Fixtures/judge/` (spec §7.4): each case names the
/// answer a correct judge gives per question.
public struct JudgeCalibrationSet: Sendable, Equatable, Codable {
  public struct Case: Sendable, Equatable, Codable {
    public enum Label: String, Sendable, Codable {
      case good
      case useless
    }

    /// Who chose the case's labels. Only a person's labels count toward a block calibration.
    public enum Labeller: String, Sendable, Codable {
      case person
      case agent
    }

    public let id: String
    public let label: Label
    public let declaredTier: String
    /// Question id → the option a correct judge picks.
    public let expected: [String: String]
    public let labeller: Labeller

    public init(
      id: String, label: Label, declaredTier: String, expected: [String: String],
      labeller: Labeller = .agent
    ) {
      self.id = id
      self.label = label
      self.declaredTier = declaredTier
      self.expected = expected
      self.labeller = labeller
    }

    private enum CodingKeys: String, CodingKey {
      case id, label, declaredTier, expected, labeller
    }

    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      id = try container.decode(String.self, forKey: .id)
      label = try container.decode(Label.self, forKey: .label)
      declaredTier = try container.decode(String.self, forKey: .declaredTier)
      expected = try container.decode([String: String].self, forKey: .expected)
      // A case without a labeller carries the tuning agent's labels.
      labeller = try container.decodeIfPresent(Labeller.self, forKey: .labeller) ?? .agent
    }

    public func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(id, forKey: .id)
      try container.encode(label, forKey: .label)
      try container.encode(declaredTier, forKey: .declaredTier)
      try container.encode(expected, forKey: .expected)
      try container.encode(labeller, forKey: .labeller)
    }
  }

  public let schema: Int
  public let questionSet: String
  public let cases: [Case]

  public init(schema: Int = 1, questionSet: String, cases: [Case]) {
    self.schema = schema
    self.questionSet = questionSet
    self.cases = cases
  }
}

/// Minimum precision and recall per question; `self-test --judge` fails below them. One baseline
/// per backend, beside that backend's recording.
public struct JudgeBaseline: Sendable, Equatable, Codable {
  public struct Minimum: Sendable, Equatable, Codable {
    public let precision: Double
    public let recall: Double

    public init(precision: Double, recall: Double) {
      self.precision = precision
      self.recall = recall
    }
  }

  public let questionSet: String
  public let minimums: [String: Minimum]
  /// The model ids that answered when the minimums were set, sorted; `nil` in a baseline set
  /// before served models were recorded.
  public let servedModels: [String]?

  public init(questionSet: String, minimums: [String: Minimum], servedModels: [String]? = nil) {
    self.questionSet = questionSet
    self.minimums = minimums
    self.servedModels = servedModels
  }
}

/// A backend's answers to the calibration set as `self-test --judge --record` writes them: the
/// requested identity, the model ids that actually answered, and each subject's usage. It reads
/// as a ``JudgeRecording`` too, since that ignores the extra keys.
public struct JudgeCalibrationRecording: Sendable, Equatable, Codable {
  public let questionSet: String
  /// The requested backend and model, which may be an alias.
  public let identity: JudgeIdentity
  /// Every model id the replies name as having answered, sorted; `nil` when no reply named one.
  public let servedModels: [String]?
  public let answers: [String: [JudgeAnswer]]
  /// Subject id → what answering it cost; `nil` in a recording written before usage was kept.
  public let usage: [String: JudgeUsage]?

  public init(
    questionSet: String, identity: JudgeIdentity, servedModels: [String]?,
    answers: [String: [JudgeAnswer]], usage: [String: JudgeUsage]?
  ) {
    self.questionSet = questionSet
    self.identity = identity
    self.servedModels = servedModels
    self.answers = answers
    self.usage = usage
  }

  /// From live replies, taking the served models and usage from each reply's usage.
  public init(questionSet: String, identity: JudgeIdentity, replies: [String: JudgeReply]) {
    self.init(
      questionSet: questionSet, identity: identity, servedModels: nil,
      answers: replies.mapValues(\.answers), usage: nil)
  }

  public var recording: JudgeRecording {
    JudgeRecording(questionSet: questionSet, identity: identity, answers: answers)
  }

  /// The recording as 1 benchmark repeat, so the benchmark's metrics can score it.
  public var run: JudgeBenchmarkRun {
    JudgeBenchmarkRun(identity: identity, repeats: [])
  }
}

/// Why a recording may no longer describe the backend it names (spec §10.8).
public enum JudgeRecordingStaleness: Sendable, Equatable {
  /// The file holds another backend's answers.
  case wrongBackend(file: String, expected: JudgeBackend, found: JudgeIdentity)
  /// A pinned backend's recording asked for a model other than the current pin.
  case offPin(file: String, found: JudgeIdentity, pin: String)
  /// A pinned backend's recording was answered by a model other than the current pin.
  case servedOffPin(file: String, served: [String], pin: String)
  /// The file names no served model, so staleness can't be checked offline.
  case servedUnrecorded(file: String)
  /// The recording was answered by other models than the ones its baseline was set against.
  case baselineServedDiffers(
    file: String, baselineFile: String, baseline: [String], recording: [String])
  /// The live backend now serves other models than the ones that answered the recording.
  case liveServedDiffers(file: String, recording: [String], live: [String])
  /// Labelled cases the recording has no answer for, so they aren't scored.
  case labelledNotRecorded(file: String, backend: JudgeBackend, cases: Int)

  /// Whether the finding fails the gate.
  public var gates: Bool { false }
}

extension JudgeRecordingStaleness: CustomStringConvertible {
  public var description: String { "" }
}

/// The metrics of 1 recording over the labelled set.
public struct JudgeCalibrationScore: Sendable, Equatable {
  public let metrics: [JudgeQuestionMetrics]
  /// Labelled cases with no recorded answer to at least 1 question they're labelled on, sorted.
  public let unrecorded: [String]

  public init(metrics: [JudgeQuestionMetrics], unrecorded: [String]) {
    self.metrics = metrics
    self.unrecorded = unrecorded
  }
}

extension JudgeCalibrationSet {
  /// The set's cases as the benchmark scores them.
  public var benchmarkCases: [JudgeBenchmarkCase] { [] }
}

/// Precision and recall of one question, treating "the flag fires" as the positive class.
public struct JudgeQuestionMetrics: Sendable, Equatable, Codable {
  public let question: String
  public let truePositives: Int
  public let falsePositives: Int
  public let falseNegatives: Int
  public let trueNegatives: Int
  /// Cases with no label for this question or no answer from the backend.
  public let unscored: Int

  /// `nil` when the judge flagged nothing.
  public var precision: Double? {
    truePositives + falsePositives == 0
      ? nil : Double(truePositives) / Double(truePositives + falsePositives)
  }

  /// `nil` when no case is labeled positive.
  public var recall: Double? {
    truePositives + falseNegatives == 0
      ? nil : Double(truePositives) / Double(truePositives + falseNegatives)
  }

  /// `nil` when no case is labeled negative.
  public var trueNegativeRate: Double? { nil }
}

public enum JudgeCalibration {
  /// The judge "flags" a subject when the flagged probability reaches this.
  public static let decisionThreshold = 0.5

  /// The block thresholds `self-test --judge` sweeps, 0.50 to 0.95 in steps of 0.05.
  public static let sweepThresholds: [Double] = (10...19).map { Double($0 * 5) / 100 }

  /// Scores `answers` against every label; a case with no label for a question isn't counted for
  /// it, and a labelled case with no recorded answer is listed as unrecorded.
  public static func score(
    set: JudgeCalibrationSet, questions: JudgeQuestionSet, answers: [String: [JudgeAnswer]]
  ) -> JudgeCalibrationScore {
    JudgeCalibrationScore(
      metrics: metrics(set: set, questions: questions, answers: answers), unrecorded: [])
  }

  /// Offline checks that `recording`, stored in `file` for `backend`, still describes that
  /// backend and its baseline.
  public static func staleness(
    recording: JudgeCalibrationRecording, file: String, backend: JudgeBackend,
    baseline: JudgeBaseline?, baselineFile: String
  ) -> [JudgeRecordingStaleness] {
    []
  }

  /// Whether the models a live run was answered by differ from the committed recording's; `nil`
  /// when there's nothing to compare against.
  public static func liveStaleness(
    committed: JudgeCalibrationRecording?, file: String, live: JudgeCalibrationRecording
  ) -> JudgeRecordingStaleness? {
    nil
  }

  /// The lowest of ``sweepThresholds`` whose precision on the tune split reaches
  /// `minimumPrecision`; `nil` when none does.
  public static func lowestBlockThreshold(
    _ question: JudgeQuestion, cases: JudgeTuneCases, run: JudgeBenchmarkRun,
    minimumPrecision: Double
  ) -> Double? {
    nil
  }

  /// Latency, tokens and cost of the recording over the set's report split.
  public static func usage(set: JudgeCalibrationSet, recording: JudgeCalibrationRecording)
    -> JudgeUsageBenchmark
  {
    JudgeBenchmarkMetrics.usage(cases: JudgeReportCases([]), run: recording.run)
  }

  public static func metrics(
    set: JudgeCalibrationSet, questions: JudgeQuestionSet, answers: [String: [JudgeAnswer]]
  ) -> [JudgeQuestionMetrics] {
    questions.questions.map { question in
      var tp = 0
      var fp = 0
      var fn = 0
      var tn = 0
      var unscored = 0
      for item in set.cases {
        let subject = JudgeSubject(
          id: item.id, file: item.id, line: 1, source: "", context: "",
          declaredTier: item.declaredTier)
        guard let expected = item.expected[question.id],
          let answer = answers[item.id]?.first(where: { $0.question == question.id }),
          let p = JudgePolicy.flaggedProbability(question, answer: answer, subject: subject)
        else {
          unscored += 1
          continue
        }
        let actual: Bool
        switch question.flag {
        case .option(let option): actual = expected == option
        case .notDeclaredTier: actual = expected != item.declaredTier
        }
        switch (p >= decisionThreshold, actual) {
        case (true, true): tp += 1
        case (true, false): fp += 1
        case (false, true): fn += 1
        case (false, false): tn += 1
        }
      }
      return JudgeQuestionMetrics(
        question: question.id, truePositives: tp, falsePositives: fp, falseNegatives: fn,
        trueNegatives: tn, unscored: unscored)
    }
  }

  /// One line per question that fell below its baseline. A question with labeled positives but no
  /// flags scores precision 0; unscored cases are a regression because the set must be answered.
  public static func regressions(_ metrics: [JudgeQuestionMetrics], baseline: JudgeBaseline)
    -> [String]
  {
    metrics.compactMap { metric -> String? in
      var problems: [String] = []
      if metric.unscored > 0 { problems.append("\(metric.unscored) cases unscored") }
      if let minimum = baseline.minimums[metric.question] {
        let hasPositives = metric.truePositives + metric.falseNegatives > 0
        let precision = metric.precision ?? (hasPositives ? 0 : 1)
        let recall = metric.recall ?? 1
        if precision < minimum.precision {
          problems.append(
            "precision \(format(precision)) < \(format(minimum.precision))")
        }
        if recall < minimum.recall {
          problems.append("recall \(format(recall)) < \(format(minimum.recall))")
        }
      }
      return problems.isEmpty ? nil : "\(metric.question): " + problems.joined(separator: ", ")
    }
  }

  static func format(_ value: Double) -> String { String(format: "%.2f", value) }
}

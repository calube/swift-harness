import Foundation

/// The labeled calibration set under `gate/Fixtures/judge/` (spec §7.4): each case names the
/// answer a correct judge gives per question.
public struct JudgeCalibrationSet: Sendable, Equatable, Codable {
  public struct Case: Sendable, Equatable, Codable {
    public enum Label: String, Sendable, Codable {
      case good
      case useless
    }

    public let id: String
    public let label: Label
    public let declaredTier: String
    /// Question id → the option a correct judge picks.
    public let expected: [String: String]

    public init(id: String, label: Label, declaredTier: String, expected: [String: String]) {
      self.id = id
      self.label = label
      self.declaredTier = declaredTier
      self.expected = expected
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

/// Minimum precision and recall per question; `self-test --judge` fails below them.
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

  public init(questionSet: String, minimums: [String: Minimum]) {
    self.questionSet = questionSet
    self.minimums = minimums
  }
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
}

public enum JudgeCalibration {
  /// The judge "flags" a subject when the flagged probability reaches this.
  public static let decisionThreshold = 0.5

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

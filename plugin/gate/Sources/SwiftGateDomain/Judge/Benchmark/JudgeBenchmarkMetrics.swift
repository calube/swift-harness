/// One labelled case as the benchmark scores it: the option a correct judge picks per question.
public struct JudgeBenchmarkCase: Sendable, Equatable, Codable {
  public let id: String
  /// `nil` for a subject with no tier, such as a comment; a tier question can't score it.
  public let declaredTier: String?
  /// Question id → the option a correct judge picks.
  public let expected: [String: String]

  public init(id: String, declaredTier: String?, expected: [String: String]) {
    self.id = id
    self.declaredTier = declaredTier
    self.expected = expected
  }
}

public protocol JudgeSplitKind: Sendable {
  static var split: JudgeCaseSplit { get }
}

public enum JudgeTuneSplit: JudgeSplitKind {
  public static let split = JudgeCaseSplit.tune
}

public enum JudgeReportSplit: JudgeSplitKind {
  public static let split = JudgeCaseSplit.report
}

/// The cases of 1 split. The only way to build one filters by `JudgeCaseSplit`, so a threshold
/// sweep, which takes tune cases, can't be handed a report case, and headline metrics can't be
/// handed a tune case.
public struct JudgeSplitCases<Kind: JudgeSplitKind>: Sendable, Equatable {
  public let cases: [JudgeBenchmarkCase]
  /// Cases dropped because they belong to the other split.
  public let excluded: Int

  public init(_ all: [JudgeBenchmarkCase]) {
    self.cases = []
    self.excluded = 0
  }
}

public typealias JudgeTuneCases = JudgeSplitCases<JudgeTuneSplit>
public typealias JudgeReportCases = JudgeSplitCases<JudgeReportSplit>

/// 1 backend's raw answers to a dataset.
public struct JudgeBenchmarkRun: Sendable, Equatable {
  public let identity: JudgeIdentity
  /// 1 entry per repeat. Each maps a case id to the requests that answered that case once: 1
  /// request for a backend that takes every question together, 1 per question for one that
  /// doesn't.
  public let repeats: [[String: [JudgeReply]]]

  public init(identity: JudgeIdentity, repeats: [[String: [JudgeReply]]]) {
    self.identity = identity
    self.repeats = repeats
  }
}

/// 1 of the equal-width bins of the flagged probability.
public struct JudgeReliabilityBin: Sendable, Equatable, Codable {
  public let lower: Double
  public let upper: Double
  /// The mean flagged probability of the bin's cases; `nil` for an empty bin.
  public let meanPredicted: Double?
  /// The share of the bin's cases where the flag should fire; its `n` is the bin's count.
  public let observed: JudgeProportion
}

/// The reliability curve of 1 backend on 1 question.
public struct JudgeReliability: Sendable, Equatable {
  public let bins: [JudgeReliabilityBin]
  /// Expected calibration error: the count-weighted mean gap between each bin's observed rate and
  /// mean predicted probability; `nil` with no points.
  public let calibrationError: Double?
}

/// How much a backend's answers move between repeats of the same case.
public enum JudgeStability: Sendable, Equatable, Codable {
  /// `flips` counts cases whose decision or most probable option differs between repeats.
  /// `meanStandardDeviation` is the mean over cases of the population standard deviation of the
  /// flagged probability.
  case measured(repeats: Int, flips: JudgeProportion, meanStandardDeviation: JudgeEstimate)
  /// Fewer than `JudgeBenchmarkMetrics.minimumRepeats` repeats can't show stability.
  case tooFewRepeats(Int)
}

/// Every per-question number for 1 backend, from report-split cases only.
public struct JudgeQuestionBenchmark: Sendable, Equatable, Codable {
  public let question: String
  public let identity: JudgeIdentity
  public let threshold: Double
  /// At `threshold`, from each case's majority decision over repeats, with the flag firing as the
  /// positive class.
  public let counts: JudgeQuestionMetrics
  public let precision: JudgeProportion
  /// Also the recall.
  public let truePositiveRate: JudgeProportion
  public let trueNegativeRate: JudgeProportion
  /// The most probable option of the mean distribution over repeats, against the label.
  public let accuracy: JudgeProportion
  /// The mean over cases of the squared error summed over options, from the mean distribution
  /// over repeats.
  public let brier: JudgeEstimate
  public let reliability: [JudgeReliabilityBin]
  /// Expected calibration error: the count-weighted mean gap between each bin's observed rate
  /// and mean predicted probability.
  public let calibrationError: JudgeEstimate
  public let stability: JudgeStability
}

/// 2 backends on the same question and the same cases. Each difference is the first backend's
/// number minus the second's, over the cases both answered.
public struct JudgeBackendComparison: Sendable, Equatable, Codable {
  public let question: String
  public let first: JudgeIdentity
  public let second: JudgeIdentity
  /// Cohen's κ between the 2 backends' majority decisions.
  public let kappa: JudgeEstimate
  public let brierDifference: JudgeEstimate
  public let calibrationErrorDifference: JudgeEstimate
  public let accuracyDifference: JudgeEstimate
  public let truePositiveRateDifference: JudgeEstimate
  public let trueNegativeRateDifference: JudgeEstimate
}

/// Latency, tokens and cost for 1 backend over report-split cases.
public struct JudgeUsageBenchmark: Sendable, Equatable, Codable {
  public let identity: JudgeIdentity
  /// Wall time of each request that reported usage.
  public let requestLatency: JudgePercentiles
  /// Wall time of all the requests that answered 1 case once.
  public let caseLatency: JudgePercentiles
  /// The backend's own reported time per request.
  public let backendLatency: JudgePercentiles
  public let inputTokensPerCase: JudgeEstimate
  public let outputTokensPerCase: JudgeEstimate
  public let costPerCase: JudgeEstimate
  /// 1 judgment is 1 question answered for 1 case.
  public let costPerThousandJudgments: JudgeEstimate
}

/// 1 candidate threshold, scored on tune-split cases.
public struct JudgeThresholdPoint: Sendable, Equatable, Codable {
  public let threshold: Double
  public let counts: JudgeQuestionMetrics
  public let truePositiveRate: JudgeProportion
  public let trueNegativeRate: JudgeProportion
}

/// The benchmark's metrics (spec §10.4), pure over labels and raw answers.
public enum JudgeBenchmarkMetrics {
  public static let bins = 10
  public static let minimumRepeats = 3

  public static func question(
    _ question: JudgeQuestion, cases: JudgeReportCases, run: JudgeBenchmarkRun,
    threshold: Double, seed: UInt64 = JudgeBootstrap.seed,
    resamples: Int = JudgeBootstrap.resamples
  ) -> JudgeQuestionBenchmark {
    let none = JudgeProportion(count: 0, n: 0)
    return JudgeQuestionBenchmark(
      question: question.id, identity: run.identity, threshold: threshold,
      counts: JudgeQuestionMetrics(
        question: question.id, truePositives: 0, falsePositives: 0, falseNegatives: 0,
        trueNegatives: 0, unscored: 0),
      precision: none, truePositiveRate: none, trueNegativeRate: none, accuracy: none,
      brier: .undefined(.noCases, n: 0), reliability: [],
      calibrationError: .undefined(.noCases, n: 0), stability: .tooFewRepeats(0))
  }

  public static func compare(
    _ question: JudgeQuestion, cases: JudgeReportCases, _ first: JudgeBenchmarkRun,
    _ second: JudgeBenchmarkRun, threshold: Double, seed: UInt64 = JudgeBootstrap.seed,
    resamples: Int = JudgeBootstrap.resamples
  ) -> JudgeBackendComparison {
    let none = JudgeEstimate.undefined(.noCases, n: 0)
    return JudgeBackendComparison(
      question: question.id, first: first.identity, second: second.identity, kappa: none,
      brierDifference: none, calibrationErrorDifference: none, accuracyDifference: none,
      truePositiveRateDifference: none, trueNegativeRateDifference: none)
  }

  public static func usage(cases: JudgeReportCases, run: JudgeBenchmarkRun)
    -> JudgeUsageBenchmark
  {
    let none = JudgeEstimate.undefined(.noCases, n: 0)
    return JudgeUsageBenchmark(
      identity: run.identity, requestLatency: JudgePercentiles([]),
      caseLatency: JudgePercentiles([]), backendLatency: JudgePercentiles([]),
      inputTokensPerCase: none, outputTokensPerCase: none, costPerCase: none,
      costPerThousandJudgments: none)
  }

  public static func sweep(
    _ question: JudgeQuestion, cases: JudgeTuneCases, run: JudgeBenchmarkRun,
    thresholds: [Double]
  ) -> [JudgeThresholdPoint] {
    []
  }

  /// Cohen's κ between 2 raters' decisions on the same subjects, paired by position.
  public static func kappa(_ first: [Bool], _ second: [Bool]) -> JudgeEstimate {
    JudgeEstimate(value: nil, undefined: nil, n: 0, interval: nil)
  }

  /// `bins` equal-width bins of the flagged probability, and the expected calibration error.
  public static func reliability(_ points: [(p: Double, positive: Bool)]) -> JudgeReliability {
    JudgeReliability(bins: [], calibrationError: nil)
  }
}

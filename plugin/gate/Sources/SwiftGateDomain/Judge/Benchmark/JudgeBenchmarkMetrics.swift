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
    cases = all.filter { JudgeCaseSplit.of($0.id) == Kind.split }
    excluded = all.count - cases.count
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
    let (scored, unscored) = score(question, cases: cases.cases, run: run)
    let counts = tally(question.id, scored, unscored: unscored, threshold: threshold)
    let points = scored.map { (p: $0.meanFlagged, positive: $0.positive) }
    let curve = reliability(points)
    return JudgeQuestionBenchmark(
      question: question.id, identity: run.identity, threshold: threshold, counts: counts,
      precision: JudgeProportion(
        count: counts.truePositives, n: counts.truePositives + counts.falsePositives),
      truePositiveRate: JudgeProportion(
        count: counts.truePositives, n: counts.truePositives + counts.falseNegatives),
      trueNegativeRate: JudgeProportion(
        count: counts.trueNegatives, n: counts.trueNegatives + counts.falsePositives),
      accuracy: JudgeProportion(count: scored.filter(\.correct).count, n: scored.count),
      brier: .of(
        mean(scored.map(\.brier)), n: scored.count,
        interval: JudgeBootstrap.interval(cases: scored.count, resamples: resamples, seed: seed) {
          draw in mean(draw.map { scored[$0].brier })
        }),
      reliability: curve.bins,
      calibrationError: .of(
        curve.calibrationError, n: scored.count,
        interval: JudgeBootstrap.interval(cases: scored.count, resamples: resamples, seed: seed) {
          draw in reliability(draw.map { points[$0] }).calibrationError
        }),
      stability: stability(scored, repeats: run.repeats.count, threshold: threshold))
  }

  public static func compare(
    _ question: JudgeQuestion, cases: JudgeReportCases, _ first: JudgeBenchmarkRun,
    _ second: JudgeBenchmarkRun, threshold: Double, seed: UInt64 = JudgeBootstrap.seed,
    resamples: Int = JudgeBootstrap.resamples
  ) -> JudgeBackendComparison {
    let a = Dictionary(
      score(question, cases: cases.cases, run: first).scored.map { ($0.id, $0) },
      uniquingKeysWith: { kept, _ in kept })
    let b = Dictionary(
      score(question, cases: cases.cases, run: second).scored.map { ($0.id, $0) },
      uniquingKeysWith: { kept, _ in kept })
    let pairs = cases.cases.compactMap { item in
      a[item.id].flatMap { left in b[item.id].map { (left, $0) } }
    }
    let n = pairs.count
    func estimate(_ statistic: @escaping ([Int]) -> Double?) -> JudgeEstimate {
      .of(
        statistic(Array(0..<n)), n: n,
        interval: JudgeBootstrap.interval(
          cases: n, resamples: resamples, seed: seed, statistic: statistic))
    }
    func difference(_ metric: @escaping ([ScoredCase]) -> Double?) -> JudgeEstimate {
      estimate { draw in
        guard let left = metric(draw.map { pairs[$0].0 }),
          let right = metric(draw.map { pairs[$0].1 })
        else { return nil }
        return left - right
      }
    }
    let decisions = pairs.map {
      ($0.0.decision(at: threshold), $0.1.decision(at: threshold))
    }
    var kappaEstimate = kappa(decisions.map(\.0), decisions.map(\.1))
    if let value = kappaEstimate.value {
      kappaEstimate = .defined(
        value, n: n,
        interval: JudgeBootstrap.interval(cases: n, resamples: resamples, seed: seed) { draw in
          kappa(draw.map { decisions[$0].0 }, draw.map { decisions[$0].1 }).value
        })
    }
    return JudgeBackendComparison(
      question: question.id, first: first.identity, second: second.identity,
      kappa: kappaEstimate,
      brierDifference: difference { mean($0.map(\.brier)) },
      calibrationErrorDifference: difference {
        reliability($0.map { (p: $0.meanFlagged, positive: $0.positive) }).calibrationError
      },
      accuracyDifference: difference {
        JudgeProportion(count: $0.filter(\.correct).count, n: $0.count).value
      },
      truePositiveRateDifference: difference { cases in
        let positives = cases.filter(\.positive)
        return JudgeProportion(
          count: positives.filter { $0.decision(at: threshold) }.count, n: positives.count
        ).value
      },
      trueNegativeRateDifference: difference { cases in
        let negatives = cases.filter { !$0.positive }
        return JudgeProportion(
          count: negatives.filter { !$0.decision(at: threshold) }.count, n: negatives.count
        ).value
      })
  }

  public static func usage(cases: JudgeReportCases, run: JudgeBenchmarkRun)
    -> JudgeUsageBenchmark
  {
    var requestWall: [Int] = []
    var caseWall: [Int] = []
    var backendTime: [Int] = []
    var inputTokens: [Int] = []
    var outputTokens: [Int] = []
    var costs: [Double] = []
    var costedJudgments = 0
    for repeatAnswers in run.repeats {
      for item in cases.cases {
        guard let replies = repeatAnswers[item.id], !replies.isEmpty else { continue }
        let usages = replies.map(\.usage)
        requestWall += usages.compactMap { $0?.wallMilliseconds }
        backendTime += usages.compactMap { $0?.backendMilliseconds }
        // A case's total counts only when every request behind it reported the field, so a
        // partial sum never passes for a whole one.
        if let walls = all(usages.map { $0?.wallMilliseconds }) { caseWall.append(sum(walls)) }
        if let input = all(usages.map { $0?.inputTokens }) { inputTokens.append(sum(input)) }
        if let output = all(usages.map { $0?.outputTokens }) { outputTokens.append(sum(output)) }
        if let cost = all(usages.map { $0?.costUSD }) {
          costs.append(cost.reduce(0, +))
          costedJudgments += Set(replies.flatMap(\.answers).map(\.question)).count
        }
      }
    }
    let totalCost = costs.reduce(0, +)
    return JudgeUsageBenchmark(
      identity: run.identity, requestLatency: JudgePercentiles(requestWall),
      caseLatency: JudgePercentiles(caseWall), backendLatency: JudgePercentiles(backendTime),
      inputTokensPerCase: .of(mean(inputTokens.map(Double.init)), n: inputTokens.count),
      outputTokensPerCase: .of(mean(outputTokens.map(Double.init)), n: outputTokens.count),
      costPerCase: .of(mean(costs), n: costs.count),
      costPerThousandJudgments: .of(
        costedJudgments == 0 ? nil : totalCost / Double(costedJudgments) * 1000,
        n: costedJudgments))
  }

  public static func sweep(
    _ question: JudgeQuestion, cases: JudgeTuneCases, run: JudgeBenchmarkRun,
    thresholds: [Double]
  ) -> [JudgeThresholdPoint] {
    let (scored, unscored) = score(question, cases: cases.cases, run: run)
    return thresholds.map { threshold in
      let counts = tally(question.id, scored, unscored: unscored, threshold: threshold)
      return JudgeThresholdPoint(
        threshold: threshold, counts: counts,
        truePositiveRate: JudgeProportion(
          count: counts.truePositives, n: counts.truePositives + counts.falseNegatives),
        trueNegativeRate: JudgeProportion(
          count: counts.trueNegatives, n: counts.trueNegatives + counts.falsePositives))
    }
  }

  /// Cohen's κ between 2 raters' decisions on the same subjects, paired by position.
  public static func kappa(_ first: [Bool], _ second: [Bool]) -> JudgeEstimate {
    let n = min(first.count, second.count)
    guard n > 0 else { return .undefined(.noCases, n: 0) }
    let pairs = zip(first, second)
    let total = Double(n)
    let observed = Double(pairs.filter { $0 == $1 }.count) / total
    let firstYes = Double(first.prefix(n).filter { $0 }.count) / total
    let secondYes = Double(second.prefix(n).filter { $0 }.count) / total
    let chance = firstYes * secondYes + (1 - firstYes) * (1 - secondYes)
    guard chance < 1 else { return .undefined(.chanceAgreementIsCertain, n: n) }
    return .defined((observed - chance) / (1 - chance), n: n)
  }

  /// `bins` equal-width bins of the flagged probability, and the expected calibration error.
  public static func reliability(_ points: [(p: Double, positive: Bool)]) -> JudgeReliability {
    var members = Array(repeating: [(p: Double, positive: Bool)](), count: bins)
    for point in points {
      members[min(bins - 1, max(0, Int(point.p * Double(bins))))].append(point)
    }
    let table = members.enumerated().map { index, inBin in
      JudgeReliabilityBin(
        lower: Double(index) / Double(bins), upper: Double(index + 1) / Double(bins),
        meanPredicted: mean(inBin.map(\.p)),
        observed: JudgeProportion(count: inBin.filter(\.positive).count, n: inBin.count))
    }
    guard !points.isEmpty else { return JudgeReliability(bins: table, calibrationError: nil) }
    let error = table.reduce(0.0) { total, bin in
      guard let predicted = bin.meanPredicted, let observed = bin.observed.value else {
        return total
      }
      return total + Double(bin.observed.n) / Double(points.count) * abs(observed - predicted)
    }
    return JudgeReliability(bins: table, calibrationError: error)
  }

  /// A labelled case every repeat answered.
  struct ScoredCase {
    let id: String
    let positive: Bool
    let flagged: [Double]
    let mostLikely: [String?]
    let meanFlagged: Double
    let brier: Double
    let correct: Bool

    /// The majority over repeats; a tie goes to the mean flagged probability.
    func decision(at threshold: Double) -> Bool {
      let fired = flagged.filter { $0 >= threshold }.count
      if 2 * fired == flagged.count { return meanFlagged >= threshold }
      return 2 * fired > flagged.count
    }
  }

  /// A case scores only with a label for the question and an answer in every repeat, so every
  /// case's decision rests on the same number of repeats.
  static func score(_ question: JudgeQuestion, cases: [JudgeBenchmarkCase], run: JudgeBenchmarkRun)
    -> (scored: [ScoredCase], unscored: Int)
  {
    var scored: [ScoredCase] = []
    var unscored = 0
    for item in cases {
      let subject = JudgeSubject(
        id: item.id, file: item.id, line: 1, source: "", context: "",
        declaredTier: item.declaredTier)
      let answers = run.repeats.map { repeatAnswers in
        repeatAnswers[item.id]?.lazy.flatMap(\.answers).first { $0.question == question.id }
      }
      guard let expected = item.expected[question.id], !answers.isEmpty,
        let found = all(answers),
        let flagged = all(
          found.map { JudgePolicy.flaggedProbability(question, answer: $0, subject: subject) }),
        let positive = flagFires(question, expected: expected, declaredTier: item.declaredTier)
      else {
        unscored += 1
        continue
      }
      let options = question.options
      let meanAnswer = JudgeAnswer(
        question: question.id,
        distribution: Dictionary(
          uniqueKeysWithValues: options.map { option in
            (option, found.reduce(0) { $0 + $1.probability(of: option) } / Double(found.count))
          }),
        rationale: nil)
      scored.append(
        ScoredCase(
          id: item.id, positive: positive, flagged: flagged,
          mostLikely: found.map { $0.mostLikely(among: options) },
          meanFlagged: flagged.reduce(0, +) / Double(flagged.count),
          brier: options.reduce(0) { total, option in
            let error = meanAnswer.probability(of: option) - (option == expected ? 1 : 0)
            return total + error * error
          },
          correct: meanAnswer.mostLikely(among: options) == expected))
    }
    return (scored, unscored)
  }

  /// Whether a correct judge's `expected` answer means the flag fires; `nil` for a tier question
  /// on a case with no declared tier.
  static func flagFires(_ question: JudgeQuestion, expected: String, declaredTier: String?)
    -> Bool?
  {
    switch question.flag {
    case .option(let option): return expected == option
    case .notDeclaredTier: return declaredTier.map { expected != $0 }
    }
  }

  static func tally(_ question: String, _ scored: [ScoredCase], unscored: Int, threshold: Double)
    -> JudgeQuestionMetrics
  {
    var tp = 0
    var fp = 0
    var fn = 0
    var tn = 0
    for item in scored {
      switch (item.decision(at: threshold), item.positive) {
      case (true, true): tp += 1
      case (true, false): fp += 1
      case (false, true): fn += 1
      case (false, false): tn += 1
      }
    }
    return JudgeQuestionMetrics(
      question: question, truePositives: tp, falsePositives: fp, falseNegatives: fn,
      trueNegatives: tn, unscored: unscored)
  }

  static func stability(_ scored: [ScoredCase], repeats: Int, threshold: Double)
    -> JudgeStability
  {
    guard repeats >= minimumRepeats else { return .tooFewRepeats(repeats) }
    let flips = scored.filter { item in
      Set(item.flagged.map { $0 >= threshold }).count > 1 || Set(item.mostLikely).count > 1
    }
    let deviations = scored.map { item in
      let spread = item.flagged.reduce(0) { total, p in
        total + (p - item.meanFlagged) * (p - item.meanFlagged)
      }
      return (spread / Double(item.flagged.count)).squareRoot()
    }
    return .measured(
      repeats: repeats, flips: JudgeProportion(count: flips.count, n: scored.count),
      meanStandardDeviation: .of(mean(deviations), n: scored.count))
  }

  static func mean(_ values: [Double]) -> Double? {
    values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
  }

  static func sum(_ values: [Int]) -> Int { values.reduce(0, +) }

  /// Every value, or `nil` if any is missing.
  static func all<Value>(_ values: [Value?]) -> [Value]? {
    let found = values.compactMap { $0 }
    return found.count == values.count ? found : nil
  }
}

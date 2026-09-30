/// A 95% interval around a benchmark number.
public struct JudgeInterval: Sendable, Equatable, Codable {
  public let lower: Double
  public let upper: Double
  /// For a bootstrap interval, the resamples the statistic was defined on; a resample can drop out,
  /// as κ does when it draws only 1 decision. `nil` for a closed-form interval.
  public let resamples: Int?

  public init(lower: Double, upper: Double, resamples: Int? = nil) {
    self.lower = lower
    self.upper = upper
    self.resamples = resamples
  }
}

/// Why a benchmark number has no value. The page prints the reason; it never prints NaN or a 0
/// that stands for "nothing to divide by".
public enum JudgeUndefined: String, Sendable, Equatable, Codable {
  /// No case or request contributed, so the value would be 0/0.
  case noCases
  /// Both backends gave 1 and the same decision on every case, so chance agreement is certain
  /// and κ would be 0/0.
  case chanceAgreementIsCertain
}

/// A count out of `n`, as in `0.91 (10/11)`.
public struct JudgeProportion: Sendable, Equatable, Codable {
  public let count: Int
  public let n: Int

  public init(count: Int, n: Int) {
    self.count = count
    self.n = n
  }

  /// `nil` when `n` is 0: a rate with nothing under it is neither 0 nor 1.
  public var value: Double? { nil }

  public var undefined: JudgeUndefined? { nil }

  /// The Wilson 95% interval; `nil` when `n` is 0.
  public var wilson: JudgeInterval? { nil }

  public var description: String {
    ""
  }
}

/// A benchmark number that isn't a plain proportion (a Brier score, κ, a mean), with the n it
/// was computed over.
/// Callers build one through `defined` and `undefined`, which keep exactly 1 of `value` and
/// `undefined` set.
public struct JudgeEstimate: Sendable, Equatable, Codable {
  public let value: Double?
  /// Set exactly when `value` is `nil`.
  public let undefined: JudgeUndefined?
  public let n: Int
  public let interval: JudgeInterval?

  public static func defined(_ value: Double, n: Int, interval: JudgeInterval? = nil)
    -> JudgeEstimate
  {
    JudgeEstimate(value: value, undefined: nil, n: n, interval: interval)
  }

  public static func undefined(_ reason: JudgeUndefined, n: Int) -> JudgeEstimate {
    JudgeEstimate(value: nil, undefined: reason, n: n, interval: nil)
  }
}

public enum JudgeWilson {
  /// The standard normal quantile for a two-sided 95% interval.
  public static let z = 1.959_963_984_540_054

  /// The Wilson score interval for `count` successes out of `n`; `nil` when `n` is 0.
  public static func interval(count: Int, n: Int) -> JudgeInterval? {
    nil
  }
}

/// SplitMix64: a small generator whose sequence is fixed by its seed on every platform and Swift
/// version, which the system generator doesn't promise.
public struct JudgeSeededGenerator: RandomNumberGenerator, Sendable {
  private var state: UInt64

  public init(seed: UInt64) { self.state = seed }

  public mutating func next() -> UInt64 {
    state
  }
}

/// A percentile bootstrap over cases. Each resample draws case indices with replacement, and
/// every statistic in a comparison sees the same indices, so a difference between 2 backends is
/// paired case by case.
public enum JudgeBootstrap {
  public static let resamples = 2000
  public static let seed: UInt64 = 20_260_930

  /// The 2.5th and 97.5th percentiles of `statistic` over `resamples` draws of `cases` indices.
  /// A resample where the statistic is `nil` drops out and the interval counts only the rest;
  /// `nil` when no resample is defined or there are no cases.
  public static func interval(
    cases: Int, resamples: Int = resamples, seed: UInt64 = seed,
    statistic: ([Int]) -> Double?
  ) -> JudgeInterval? {
    nil
  }
}

/// Nearest-rank percentiles: always an observed value, so 1 sample is its own p50 and p95.
public enum JudgePercentile {
  /// `nil` for no values.
  public static func of(_ values: [Int], percent: Int) -> Int? {
    nil
  }
}

/// p50 and p95 of a set of millisecond timings, with how many there were.
public struct JudgePercentiles: Sendable, Equatable, Codable {
  public let n: Int
  public let p50: Int?
  public let p95: Int?

  public init(_ milliseconds: [Int]) {
    self.n = 0
    self.p50 = nil
    self.p95 = nil
  }
}

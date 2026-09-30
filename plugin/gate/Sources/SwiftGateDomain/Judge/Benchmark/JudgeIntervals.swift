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
  public var value: Double? { n == 0 ? nil : Double(count) / Double(n) }

  public var undefined: JudgeUndefined? { n == 0 ? .noCases : nil }

  /// The Wilson 95% interval; `nil` when `n` is 0.
  public var wilson: JudgeInterval? { JudgeWilson.interval(count: count, n: n) }

  public var description: String {
    guard let value else { return "undefined (\(count)/\(n))" }
    return "\(String(format: "%.2f", value)) (\(count)/\(n))"
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

  /// `.noCases` when `value` is `nil`.
  static func of(_ value: Double?, n: Int, interval: JudgeInterval? = nil) -> JudgeEstimate {
    value.map { .defined($0, n: n, interval: interval) } ?? .undefined(.noCases, n: n)
  }
}

public enum JudgeWilson {
  /// The standard normal quantile for a two-sided 95% interval.
  public static let z = 1.959_963_984_540_054

  /// The Wilson score interval for `count` successes out of `n`; `nil` when `n` is 0.
  public static func interval(count: Int, n: Int) -> JudgeInterval? {
    guard n > 0 else { return nil }
    let total = Double(n)
    let p = Double(count) / total
    let z2 = z * z
    let denominator = 1 + z2 / total
    let center = (p + z2 / (2 * total)) / denominator
    let half = z * (p * (1 - p) / total + z2 / (4 * total * total)).squareRoot() / denominator
    return JudgeInterval(lower: max(0, center - half), upper: min(1, center + half))
  }
}

/// SplitMix64: a small generator whose sequence is fixed by its seed on every platform and Swift
/// version, which the system generator doesn't promise.
public struct JudgeSeededGenerator: RandomNumberGenerator, Sendable {
  private var state: UInt64

  public init(seed: UInt64) { state = seed }

  public mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

  /// A uniform index below `bound`, by the high word of a full-width multiply, so it doesn't
  /// depend on the standard library's `random(in:using:)`.
  mutating func index(below bound: Int) -> Int {
    Int(next().multipliedFullWidth(by: UInt64(bound)).high)
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
    guard cases > 0, resamples > 0 else { return nil }
    var generator = JudgeSeededGenerator(seed: seed)
    var values: [Double] = []
    values.reserveCapacity(resamples)
    for _ in 0..<resamples {
      let draw = (0..<cases).map { _ in generator.index(below: cases) }
      if let value = statistic(draw) { values.append(value) }
    }
    guard !values.isEmpty else { return nil }
    values.sort()
    return JudgeInterval(
      lower: values[JudgePercentile.rank(perMille: 25, of: values.count) - 1],
      upper: values[JudgePercentile.rank(perMille: 975, of: values.count) - 1],
      resamples: values.count)
  }
}

/// Nearest-rank percentiles: always an observed value, so 1 sample is its own p50 and p95.
public enum JudgePercentile {
  /// `nil` for no values.
  public static func of(_ values: [Int], percent: Int) -> Int? {
    guard !values.isEmpty else { return nil }
    return values.sorted()[rank(perMille: percent * 10, of: values.count) - 1]
  }

  /// The 1-based nearest rank, ceil(perMille × count / 1000), computed in integers so 95% of 20
  /// is exactly rank 19.
  static func rank(perMille: Int, of count: Int) -> Int {
    max(1, min(count, (perMille * count + 999) / 1000))
  }
}

/// p50 and p95 of a set of millisecond timings, with how many there were.
public struct JudgePercentiles: Sendable, Equatable, Codable {
  public let n: Int
  public let p50: Int?
  public let p95: Int?

  public init(_ milliseconds: [Int]) {
    n = milliseconds.count
    p50 = JudgePercentile.of(milliseconds, percent: 50)
    p95 = JudgePercentile.of(milliseconds, percent: 95)
  }
}

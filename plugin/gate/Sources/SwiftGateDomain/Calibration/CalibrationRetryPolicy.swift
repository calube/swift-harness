/// How one attempt at a calibration case went: every label check met, or at least one missed.
public enum CalibrationAttemptOutcome: String, Sendable, Equatable, Codable {
  case pass
  case miss
}

/// When a calibration case that missed is run again, and what its attempts add up to. A model
/// can land on either side of an ambiguous case from one run to the next, so a single miss says
/// little; an agent that is wrong on the case misses again. A case passes on its first attempt,
/// or, after a miss, once ``requiredPasses`` of its attempts pass within ``maxAttempts``. It
/// fails as soon as the attempts left can't reach that.
public struct CalibrationRetryPolicy: Sendable, Equatable {
  /// What the attempts so far decide.
  public enum Verdict: Sendable, Equatable {
    case passed
    case failed
    /// Undecided: run the case once more.
    case retry
  }

  public let maxAttempts: Int
  public let requiredPasses: Int

  public init(maxAttempts: Int, requiredPasses: Int) {
    self.maxAttempts = maxAttempts
    self.requiredPasses = requiredPasses
  }

  /// One attempt, which must pass.
  public static let singleAttempt = CalibrationRetryPolicy(maxAttempts: 1, requiredPasses: 1)

  /// A miss earns up to two more attempts, and the case passes when two of its attempts do.
  public static let twoOfThree = CalibrationRetryPolicy(maxAttempts: 3, requiredPasses: 2)

  public func verdict(_ attempts: [CalibrationAttemptOutcome]) -> Verdict {
    guard let first = attempts.first else { return .retry }
    if first == .pass { return .passed }
    let passes = attempts.filter { $0 == .pass }.count
    if passes >= requiredPasses { return .passed }
    let left = max(maxAttempts - attempts.count, 0)
    return passes + left < requiredPasses ? .failed : .retry
  }

  /// Whether a run passes: every case's attempts are ``Verdict/passed``.
  public func runPassed(_ cases: [[CalibrationAttemptOutcome]]) -> Bool {
    cases.allSatisfy { verdict($0) == .passed }
  }
}

/// What the Stop hook remembers for one session between stops.
public struct StopState: Sendable, Equatable, Codable {
  public struct RedMemo: Sendable, Equatable, Codable {
    public let fingerprint: String
    public let summary: String

    public init(fingerprint: String, summary: String) {
      self.fingerprint = fingerprint
      self.summary = summary
    }
  }

  /// Stops blocked in a row since the last fresh stop.
  public var consecutiveBlocks: Int
  /// The last RED verdict and the content it judged, reused while the content is unchanged.
  public var lastRed: RedMemo?

  public init(consecutiveBlocks: Int = 0, lastRed: RedMemo? = nil) {
    self.consecutiveBlocks = consecutiveBlocks
    self.lastRed = lastRed
  }
}

public enum StopPlan: Sendable, Equatable {
  case skip
  case reuseRed(summary: String)
  case run
}

public enum StopDecision: Sendable, Equatable {
  case allow
  case block(reason: String)
  case release(message: String)
  case warn(message: String)
}

/// The Stop hook's policy (spec §8 safeguards): block a RED stop, skip content that already passed,
/// give up after three consecutive blocks with the turn stamped RED, and never count an environment
/// failure (`blocked`) as a strike.
///
/// Claude Code sets `stop_hook_active` when a stop follows a Stop-hook block. A stop without it is a
/// new turn's first attempt, so the strike count starts over; with it, blocks are consecutive.
public enum StopGate {
  public static let maxConsecutiveBlocks = 3
  public static let releaseStamp = "RED — not done"

  public struct Outcome: Sendable, Equatable {
    public let decision: StopDecision
    public let state: StopState
    public let lastGreen: String?
  }

  public static func plan(fingerprint: String?, lastGreen: String?, state: StopState, reentry: Bool)
    -> StopPlan
  {
    guard let fingerprint else { return .run }
    if fingerprint == lastGreen { return .skip }
    if let red = state.lastRed, red.fingerprint == fingerprint {
      return .reuseRed(summary: red.summary)
    }
    return .run
  }

  /// - Parameter fingerprint: the content judged; `nil` when it could not be computed, in which
  ///   case nothing is remembered about it.
  public static func decide(
    verdict: Verdict, summary: String, fingerprint: String?, state: StopState, reentry: Bool
  ) -> Outcome {
    var state = state
    if !reentry { state.consecutiveBlocks = 0 }
    switch verdict {
    case .green:
      return Outcome(decision: .allow, state: StopState(), lastGreen: fingerprint)
    case .blocked:
      return Outcome(
        decision: .warn(
          message:
            "swiftgate could not judge this change (BLOCKED, an environment problem, not a "
            + "verdict on the code); the stop was allowed.\n\(summary)"),
        state: state, lastGreen: nil)
    case .red:
      state.lastRed = fingerprint.map { StopState.RedMemo(fingerprint: $0, summary: summary) }
      guard state.consecutiveBlocks < maxConsecutiveBlocks else {
        state.consecutiveBlocks = 0
        return Outcome(
          decision: .release(
            message:
              "\(releaseStamp): `swiftgate check --tier fast` is still RED after "
              + "\(maxConsecutiveBlocks) blocked stops, so the turn ended unfinished.\n\(summary)"),
          state: state, lastGreen: nil)
      }
      state.consecutiveBlocks += 1
      return Outcome(
        decision: .block(
          reason:
            "`swiftgate check --tier fast` is RED (stop blocked \(state.consecutiveBlocks)/"
            + "\(maxConsecutiveBlocks)). Fix the findings below, then finish.\n\(summary)"),
        state: state, lastGreen: nil)
    }
  }
}

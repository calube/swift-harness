/// Outcome of a gate run, or of any tier or step within one.
///
/// - `green`: the evidence shows the code is good.
/// - `red`: the evidence shows the code is wrong. The remedy is a code change.
/// - `blocked`: the environment prevented gathering evidence (Xcode mismatch, missing simulator
///   runtime, disk, a timed-out process). The remedy is an environment change, never a code change.
///
/// Merging takes the most severe verdict: `red` > `blocked` > `green`.
/// - `red` dominates `blocked`: a red result proves the code must change whatever the environment
///   does. Reporting `blocked` would send the caller to fix the environment first, only to
///   rediscover the same red afterwards.
/// - `blocked` dominates `green`: a part that could not run proves nothing, so the whole cannot
///   claim green.
/// - Merging nothing yields `green` (the identity): a tier plan that selects no work, such as a
///   doc-only change in the fast tier, has nothing wrong with it. Rules that demand evidence (for
///   example "more than zero tests executed") must produce their own `red`/`blocked`.
public enum Verdict: String, Sendable, Codable, CaseIterable {
  case green = "GREEN"
  case red = "RED"
  case blocked = "BLOCKED"

  public func merged(with other: Verdict) -> Verdict {
    other.precedence > precedence ? other : self
  }

  public static func merged(_ verdicts: some Sequence<Verdict>) -> Verdict {
    verdicts.reduce(.green) { $0.merged(with: $1) }
  }

  private var precedence: Int {
    switch self {
    case .green: 0
    case .blocked: 1
    case .red: 2
    }
  }
}

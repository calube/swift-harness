/// 2 clean gate runs of 1 command and tier list on 1 tree that reached different verdicts.
public struct GateFlip: Sendable, Equatable {
  public let command: String?
  public let tiers: [Tier]
  public let treeHash: String
  public let earlierRunID: String?
  public let earlierVerdict: Verdict
  public let laterRunID: String?
  public let laterVerdict: Verdict
  /// For a RED then GREEN flip, the RED's rules that had more findings than the GREEN's; empty
  /// for any other order.
  public let overturnedRules: [String]

  public init(
    command: String?, tiers: [Tier], treeHash: String, earlierRunID: String?,
    earlierVerdict: Verdict, laterRunID: String?, laterVerdict: Verdict, overturnedRules: [String]
  ) {
    self.command = command
    self.tiers = tiers
    self.treeHash = treeHash
    self.earlierRunID = earlierRunID
    self.earlierVerdict = earlierVerdict
    self.laterRunID = laterRunID
    self.laterVerdict = laterVerdict
    self.overturnedRules = overturnedRules
  }
}

/// A RED for a rule, then the command's next run with more allowances for that rule and some of
/// the RED's finding paths no longer named: the finding was waived, not fixed.
public struct AllowOverturn: Sendable, Equatable {
  public let command: String?
  public let rule: String
  /// The RED's finding paths the later run no longer names.
  public let paths: [String]
  public let redRunID: String?
  public let laterRunID: String?

  public init(
    command: String?, rule: String, paths: [String], redRunID: String?, laterRunID: String?
  ) {
    self.command = command
    self.rule = rule
    self.paths = paths
    self.redRunID = redRunID
    self.laterRunID = laterRunID
  }
}

/// Flips and overturned findings over `gate.run` events.
public struct WrongGateFindings: Sendable, Equatable {
  public let flips: [GateFlip]
  public let allowOverturns: [AllowOverturn]
  /// Runs with a tree hash and `dirty: false`: the only runs a flip compares.
  public let cleanRuns: Int
  /// Runs left out of flips: dirty, or with no tree hash.
  public let dirtyRuns: Int
  /// Consecutive clean runs of 1 command, tier list and tree: the flip rate's n.
  public let comparedPairs: Int
  /// RED runs followed by another run of their command: the allow overturns' n.
  public let followedReds: Int

  public init(
    flips: [GateFlip], allowOverturns: [AllowOverturn], cleanRuns: Int, dirtyRuns: Int,
    comparedPairs: Int, followedReds: Int
  ) {
    self.flips = flips
    self.allowOverturns = allowOverturns
    self.cleanRuns = cleanRuns
    self.dirtyRuns = dirtyRuns
    self.comparedPairs = comparedPairs
    self.followedReds = followedReds
  }

  /// The findings over the `gate.run` events in `events`, which are oldest first.
  public init(events: [HarnessEvent]) {
    self.flips = []
    self.allowOverturns = []
    self.cleanRuns = 0
    self.dirtyRuns = 0
    self.comparedPairs = 0
    self.followedReds = 0
  }
}

/// Gates that were wrong: flips, overturned findings and misses.
public struct WrongGatesSection: EventSummarySection {
  public init() {}

  public var id: EventSummarySectionID { .wrongGates }

  public func summarize(_ input: EventSummaryInput) -> EventSummarySectionReport? {
    nil
  }
}

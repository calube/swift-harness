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
    let runs: [(event: HarnessEvent, run: GateRunEvent)] = events.compactMap {
      guard case .gateRun(let run) = $0.payload else { return nil }
      return ($0, run)
    }

    // A dirty tree can change a verdict without changing `HEAD`, so only clean runs with a tree
    // hash are compared; a run whose dirtiness git couldn't report counts as dirty.
    struct FlipKey: Hashable {
      let command: String?
      let tiers: [Tier]
      let treeHash: String
    }
    var lastClean: [FlipKey: (event: HarnessEvent, run: GateRunEvent)] = [:]
    var flips: [GateFlip] = []
    var cleanRuns = 0
    var comparedPairs = 0
    for entry in runs {
      guard let treeHash = entry.run.treeHash, entry.run.dirty == false else { continue }
      cleanRuns += 1
      let key = FlipKey(
        command: entry.run.command, tiers: entry.run.tiers.map(\.tier), treeHash: treeHash)
      defer { lastClean[key] = entry }
      guard let earlier = lastClean[key] else { continue }
      comparedPairs += 1
      guard earlier.run.verdict != entry.run.verdict else { continue }
      let overturned =
        earlier.run.verdict == .red && entry.run.verdict == .green
        ? earlier.run.ruleCounts.filter { $0.value > entry.run.ruleCounts[$0.key, default: 0] }
          .keys.sorted()
        : []
      flips.append(
        GateFlip(
          command: entry.run.command, tiers: key.tiers, treeHash: treeHash,
          earlierRunID: earlier.event.runID, earlierVerdict: earlier.run.verdict,
          laterRunID: entry.event.runID, laterVerdict: entry.run.verdict,
          overturnedRules: overturned))
    }

    // An allowance changes the tree, so a RED is compared with its command's next run, clean or not.
    var pendingRed: [String?: (event: HarnessEvent, run: GateRunEvent)] = [:]
    var overturns: [AllowOverturn] = []
    var followedReds = 0
    for entry in runs {
      let command = entry.run.command
      if let red = pendingRed.removeValue(forKey: command) {
        followedReds += 1
        let gone = red.run.findingPaths.filter { !entry.run.findingPaths.contains($0) }
        if !gone.isEmpty {
          for rule in red.run.ruleCounts.keys.sorted()
          where entry.run.allowanceCounts[rule, default: 0]
            > red.run.allowanceCounts[rule, default: 0]
          {
            overturns.append(
              AllowOverturn(
                command: command, rule: rule, paths: gone, redRunID: red.event.runID,
                laterRunID: entry.event.runID))
          }
        }
      }
      if entry.run.verdict == .red { pendingRed[command] = entry }
    }

    self.init(
      flips: flips, allowOverturns: overturns, cleanRuns: cleanRuns,
      dirtyRuns: runs.count - cleanRuns, comparedPairs: comparedPairs, followedReds: followedReds)
  }
}

/// Gates that were wrong: flips, overturned findings and misses.
public struct WrongGatesSection: EventSummarySection {
  /// The build state misses join task gates to; `nil` when it wasn't read.
  public let builds: BuildJoin?

  public init(builds: BuildJoin? = nil) {
    self.builds = builds
  }

  public var id: EventSummarySectionID { .wrongGates }

  public func summarize(_ input: EventSummaryInput) -> EventSummarySectionReport? {
    let events = input.events.map(\.event)
    let runs = events.filter { $0.kind == .gateRun }.count
    guard runs > 0 else { return nil }
    let found = WrongGateFindings(events: events)
    func label(_ command: String?) -> String { command ?? "no command" }
    func run(_ id: String?) -> String { id ?? "unnamed run" }

    var metrics = [
      EventSummaryMetric(
        name: "clean-runs", group: [], value: Double(found.cleanRuns), unit: .count, n: runs),
      EventSummaryMetric(
        name: "dirty-runs", group: [], value: Double(found.dirtyRuns), unit: .count, n: runs),
      EventSummaryMetric(
        name: "flips", group: [], value: Double(found.flips.count), unit: .count,
        n: found.comparedPairs),
      EventSummaryMetric(
        name: "allow-overturns", group: [], value: Double(found.allowOverturns.count),
        unit: .count, n: found.followedReds),
    ]
    if found.comparedPairs > 0 {
      metrics.append(
        EventSummaryMetric(
          name: "flip-rate", group: [],
          value: Double(found.flips.count) / Double(found.comparedPairs), unit: .share,
          n: found.comparedPairs))
    }

    var lines = [
      "flips: \(found.flips.count) in \(found.comparedPairs) compared pairs of clean runs "
        + "(n=\(found.comparedPairs)); \(found.cleanRuns) clean, \(found.dirtyRuns) dirty or "
        + "unhashed runs not compared (n=\(runs))"
    ]
    for flip in found.flips {
      let tiers = flip.tiers.map(\.rawValue).joined(separator: ",")
      var line =
        "flip: \(label(flip.command)) [\(tiers)] tree \(flip.treeHash.prefix(12)): "
        + "\(flip.earlierVerdict.rawValue) run \(run(flip.earlierRunID)), then "
        + "\(flip.laterVerdict.rawValue) run \(run(flip.laterRunID))"
      if !flip.overturnedRules.isEmpty {
        line += "; overturned \(flip.overturnedRules.joined(separator: ", "))"
      }
      lines.append(line)
    }
    lines.append(
      "overturned by an allow: \(found.allowOverturns.count) in \(found.followedReds) REDs "
        + "followed by a run (n=\(found.followedReds))")
    for overturn in found.allowOverturns {
      lines.append(
        "allow: \(label(overturn.command)) \(overturn.rule): RED run \(run(overturn.redRunID)), "
          + "then run \(run(overturn.laterRunID)) waived "
          + overturn.paths.joined(separator: ", "))
    }
    return EventSummarySectionReport(id: id, state: .reported, lines: lines, metrics: metrics)
  }
}

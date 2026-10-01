/// p50, p95 and standard deviation of millisecond timings, with how many there were.
public struct TimingStats: Sendable, Equatable {
  public let n: Int
  /// Nearest rank, so always an observed value.
  public let p50: Int
  /// Nearest rank, so always an observed value.
  public let p95: Int
  /// Population standard deviation: 0 for a single timing.
  public let standardDeviation: Double

  public init(n: Int, p50: Int, p95: Int, standardDeviation: Double) {
    self.n = n
    self.p50 = p50
    self.p95 = p95
    self.standardDeviation = standardDeviation
  }

  /// `nil` when there are no timings.
  public init?(milliseconds: [Int]) {
    guard !milliseconds.isEmpty else { return nil }
    let sorted = milliseconds.sorted()
    func nearestRank(_ fraction: Double) -> Int {
      let rank = Int((fraction * Double(sorted.count)).rounded(.up))
      return sorted[min(max(rank, 1), sorted.count) - 1]
    }
    let count = Double(sorted.count)
    let mean = sorted.reduce(0.0) { $0 + Double($1) } / count
    let variance = sorted.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / count
    self.init(
      n: sorted.count, p50: nearestRank(0.50), p95: nearestRank(0.95),
      standardDeviation: variance.squareRoot())
  }

  /// `p50 <ms> ms, p95 <ms> ms, sd <ms> ms (n=<n>)`.
  var rendered: String {
    "p50 \(p50) ms, p95 \(p95) ms, sd \(Int(standardDeviation.rounded())) ms (n=\(n))"
  }
}

/// Gate time per command, tier and step: p50, p95, standard deviation and n.
public struct GateTimeSection: EventSummarySection {
  public init() {}

  public var id: EventSummarySectionID { .gateTime }

  /// The group a step outside any tier reports under.
  static let noTier = "no tier"
  /// The command a run that didn't name its command, or a step whose run wasn't read, reports under.
  static let noCommand = "no command"

  private struct StepKey: Hashable, Comparable {
    let command: String
    let tier: Tier?
    let step: GateStep
    let derivedData: GateDerivedData

    var group: [String] {
      [command, tier?.rawValue ?? GateTimeSection.noTier, step.rawValue, derivedData.rawValue]
    }

    static func < (lhs: StepKey, rhs: StepKey) -> Bool {
      func order(_ key: StepKey) -> (String, Int, Int, Int) {
        (
          key.command, key.tier.flatMap { Tier.allCases.firstIndex(of: $0) } ?? Tier.allCases.count,
          GateStep.allCases.firstIndex(of: key.step) ?? 0,
          GateDerivedData.allCases.firstIndex(of: key.derivedData) ?? 0
        )
      }
      return order(lhs) < order(rhs)
    }
  }

  public func summarize(_ input: EventSummaryInput) -> EventSummarySectionReport? {
    var commandOfRun: [String: String] = [:]
    var runs: [String: [Int]] = [:]
    var tiers: [String: [Tier: [Int]]] = [:]
    var steps: [StepKey: [Int]] = [:]
    for stored in input.events {
      guard case .gateRun(let run) = stored.event.payload else { continue }
      let command = run.command ?? Self.noCommand
      commandOfRun[stored.event.eventID] = command
      runs[command, default: []].append(run.milliseconds)
      for tier in run.tiers {
        tiers[command, default: [:]][tier.tier, default: []].append(tier.milliseconds)
      }
    }
    for stored in input.events {
      guard case .gateStep(let step) = stored.event.payload else { continue }
      let command = stored.event.parentID.flatMap { commandOfRun[$0] } ?? Self.noCommand
      let key = StepKey(
        command: command, tier: step.tier, step: step.step, derivedData: step.derivedData)
      steps[key, default: []].append(step.milliseconds)
    }
    guard !runs.isEmpty || !steps.isEmpty else { return nil }

    var lines: [String] = []
    var metrics: [EventSummaryMetric] = []
    func report(_ stats: TimingStats, group: [String], label: String) {
      metrics += [
        EventSummaryMetric(
          name: "p50", group: group, value: Double(stats.p50), unit: .milliseconds, n: stats.n),
        EventSummaryMetric(
          name: "p95", group: group, value: Double(stats.p95), unit: .milliseconds, n: stats.n),
        EventSummaryMetric(
          name: "sd", group: group, value: stats.standardDeviation, unit: .milliseconds,
          n: stats.n),
      ]
      lines.append("\(label): \(stats.rendered)")
    }
    let commands = Set(runs.keys).union(steps.keys.map(\.command)).sorted()
    for command in commands {
      if let stats = runs[command].flatMap(TimingStats.init(milliseconds:)) {
        report(stats, group: [command], label: command)
      } else {
        lines.append("\(command): no gate.run read")
      }
      for tier in Tier.allCases {
        guard let stats = tiers[command]?[tier].flatMap(TimingStats.init(milliseconds:)) else {
          continue
        }
        report(stats, group: [command, tier.rawValue], label: "  \(tier.rawValue)")
      }
      for key in steps.keys.filter({ $0.command == command }).sorted() {
        guard let stats = steps[key].flatMap(TimingStats.init(milliseconds:)) else { continue }
        report(
          stats, group: key.group,
          label: "  step \(key.tier?.rawValue ?? Self.noTier) \(key.step.rawValue), "
            + key.derivedData.rawValue)
      }
    }
    return EventSummarySectionReport(id: id, state: .reported, lines: lines, metrics: metrics)
  }
}

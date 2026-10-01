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
    return nil
  }
}

/// Gate time per command, tier and step: p50, p95, standard deviation and n.
public struct GateTimeSection: EventSummarySection {
  public init() {}

  public var id: EventSummarySectionID { .gateTime }

  public func summarize(_ input: EventSummaryInput) -> EventSummarySectionReport? {
    nil
  }
}

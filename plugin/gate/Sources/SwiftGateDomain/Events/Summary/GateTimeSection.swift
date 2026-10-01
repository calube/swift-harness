/// Gate time per command, tier and step: p50, p95, standard deviation and n.
public struct GateTimeSection: EventSummarySection {
  public init() {}

  public var id: EventSummarySectionID { .gateTime }

  public func summarize(_ input: EventSummaryInput) -> EventSummarySectionReport? {
    nil
  }
}

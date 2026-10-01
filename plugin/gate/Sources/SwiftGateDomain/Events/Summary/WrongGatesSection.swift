/// Gates that were wrong: flips, overturned findings and misses.
public struct WrongGatesSection: EventSummarySection {
  public init() {}

  public var id: EventSummarySectionID { .wrongGates }

  public func summarize(_ input: EventSummaryInput) -> EventSummarySectionReport? {
    nil
  }
}

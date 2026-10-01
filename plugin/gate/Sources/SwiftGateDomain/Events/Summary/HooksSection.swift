/// Hook latency per event, blocks per rule, and bypassed blocks.
public struct HooksSection: EventSummarySection {
  public init() {}

  public var id: EventSummarySectionID { .hooks }

  public func summarize(_ input: EventSummaryInput) -> EventSummarySectionReport? {
    nil
  }
}

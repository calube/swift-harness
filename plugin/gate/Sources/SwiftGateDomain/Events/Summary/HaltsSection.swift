/// Build halts: wait per reason, idle slot-minutes and retries per task.
public struct HaltsSection: EventSummarySection {
  public init() {}

  public var id: EventSummarySectionID { .halts }

  public func summarize(_ input: EventSummaryInput) -> EventSummarySectionReport? {
    nil
  }
}

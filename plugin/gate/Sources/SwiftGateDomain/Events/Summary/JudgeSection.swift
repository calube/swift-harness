/// The judge's agreement and escalation share.
public struct JudgeSection: EventSummarySection {
  public init() {}

  public var id: EventSummarySectionID { .judge }

  public func summarize(_ input: EventSummaryInput) -> EventSummarySectionReport? {
    nil
  }
}

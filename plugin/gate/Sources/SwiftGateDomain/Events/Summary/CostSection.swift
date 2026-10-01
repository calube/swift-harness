/// The cost of agents and the judge, by role, agent, model, task and design phase.
public struct CostSection: EventSummarySection {
  public init() {}

  public var id: EventSummarySectionID { .cost }

  public func summarize(_ input: EventSummaryInput) -> EventSummarySectionReport? {
    nil
  }
}

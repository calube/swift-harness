/// The cost of agents and the judge, by role, agent, model, task and design phase.
public struct CostSection: EventSummarySection {
  /// Rates for splitting a priced message's cost into cache reads and fresh input.
  public let prices: ModelPriceTable

  public init(prices: ModelPriceTable = .current) {
    self.prices = prices
  }

  public var id: EventSummarySectionID { .cost }

  public func summarize(_ input: EventSummaryInput) -> EventSummarySectionReport? {
    nil
  }
}

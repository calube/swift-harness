/// The store's size per kind and stream, its sealed segments, dropped events and damage.
public struct StoreSection: EventSummarySection {
  public init() {}

  public var id: EventSummarySectionID { .store }

  public func summarize(_ input: EventSummaryInput) -> EventSummarySectionReport? {
    nil
  }
}

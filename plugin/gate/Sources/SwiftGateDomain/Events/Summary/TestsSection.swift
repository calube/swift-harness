/// Flaky tests per tree, and the slowest tests.
public struct TestsSection: EventSummarySection {
  public init() {}

  public var id: EventSummarySectionID { .tests }

  public func summarize(_ input: EventSummaryInput) -> EventSummarySectionReport? {
    nil
  }
}

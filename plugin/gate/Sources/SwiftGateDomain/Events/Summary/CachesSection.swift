/// Hit rate and stale keys per cache.
public struct CachesSection: EventSummarySection {
  public init() {}

  public var id: EventSummarySectionID { .caches }

  public func summarize(_ input: EventSummaryInput) -> EventSummarySectionReport? {
    nil
  }
}

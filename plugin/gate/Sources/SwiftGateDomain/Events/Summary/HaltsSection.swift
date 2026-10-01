import Foundation

/// Build halts: wait per reason, idle slot-minutes and retries per task.
public struct HaltsSection: EventSummarySection {
  /// The build runs to replay; `nil` when the build state wasn't read.
  public let builds: BuildJoin?

  public init(builds: BuildJoin? = nil) {
    self.builds = builds
  }

  public var id: EventSummarySectionID { .halts }

  public func summarize(_ input: EventSummaryInput) -> EventSummarySectionReport? {
    nil
  }
}

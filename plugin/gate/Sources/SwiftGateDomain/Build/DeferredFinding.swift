import Foundation

/// A verified review finding a task's review deferred to a sibling task, because its test could
/// pass only once that sibling merged. The task's return records it as a `notes` line
/// `deferred to <sibling>: <severity> <file>: <title>`; nothing else carries it on.
public struct DeferredFinding: Sendable, Equatable, Encodable {
  /// The task whose review deferred it.
  public let task: String
  /// The sibling the test waits on.
  public let sibling: String
  /// `<severity> <file>: <title>`, as the line gives it.
  public let finding: String

  public static let linePrefix = "deferred to "

  public init(task: String, sibling: String, finding: String) {
    self.task = task
    self.sibling = sibling
    self.finding = finding
  }

  /// Each deferral line in `task`'s return `notes`, in order.
  public static func parse(notes: String, task: String) -> [DeferredFinding] {
    []
  }

  /// The deferrals a worker of `task` must pick up: each one deferred to it, and each between 2
  /// of its dependencies, whose code is on its branch by the time it starts.
  public static func owned(by task: LedgerTask, in deferrals: [DeferredFinding])
    -> [DeferredFinding]
  {
    []
  }
}

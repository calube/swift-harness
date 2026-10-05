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
  /// The heading a worker pack quotes the deferrals its task owns under.
  public static let packHeading = "Review findings deferred to this task"

  public init(task: String, sibling: String, finding: String) {
    self.task = task
    self.sibling = sibling
    self.finding = finding
  }

  /// Each deferral line in `task`'s return `notes`, in order.
  public static func parse(notes: String, task: String) -> [DeferredFinding] {
    notes.split(whereSeparator: \.isNewline).compactMap { raw in
      let line = raw.trimmingCharacters(in: .whitespaces)
      guard line.hasPrefix(linePrefix) else { return nil }
      let rest = line.dropFirst(linePrefix.count)
      guard let colon = rest.firstIndex(of: ":") else { return nil }
      let sibling = rest[..<colon].trimmingCharacters(in: .whitespaces)
      let finding = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      guard !sibling.isEmpty, !finding.isEmpty else { return nil }
      return DeferredFinding(task: task, sibling: sibling, finding: finding)
    }
  }

  /// The deferrals a worker of `task` must pick up: each one deferred to it, and each between 2
  /// of its dependencies, whose code is on its branch by the time it starts.
  public static func owned(by task: LedgerTask, in deferrals: [DeferredFinding])
    -> [DeferredFinding]
  {
    deferrals.filter {
      $0.task != task.id
        && ($0.sibling == task.id || (task.deps.contains($0.task) && task.deps.contains($0.sibling)))
    }
  }

  /// How a worker pack quotes it.
  public var packLine: String { "\(task) deferred to \(sibling): \(finding)" }
}

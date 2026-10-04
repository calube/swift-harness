import Foundation

/// The part of `ledger.json` that says which tasks have merged: each task's id and status. A
/// reader that asks only "has this task merged?", as `qa run` does for a row's `runsAfter`, reads
/// this instead of the whole ledger, so a key it never uses can't stop it.
public struct LedgerProgress: Sendable, Equatable {
  public struct Task: Sendable, Equatable, Decodable {
    public let id: String
    public let status: TaskStatus

    public init(id: String, status: TaskStatus) {
      self.id = id
      self.status = status
    }
  }

  public let tasks: [Task]

  public init(tasks: [Task]) {
    self.tasks = tasks
  }

  /// The ids of the tasks marked `done`.
  public var merged: Set<String> { Set(tasks.filter { $0.status == .done }.map(\.id)) }

  public func contains(_ id: String) -> Bool { tasks.contains { $0.id == id } }
}

public enum LedgerProgressJSON {
  public static func decode(_ data: Data) throws -> LedgerProgress {
    let ledger = try LedgerJSON.decode(data)
    return LedgerProgress(tasks: ledger.tasks.map { .init(id: $0.id, status: $0.status) })
  }
}

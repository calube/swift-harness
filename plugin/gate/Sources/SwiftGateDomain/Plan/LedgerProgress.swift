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

extension LedgerProgress: Decodable {
  private enum CodingKeys: String, CodingKey {
    case tasks
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(tasks: try c.decode([Task].self, forKey: .tasks))
  }
}

/// Reads only `tasks[].id` and `tasks[].status`; every other key, `waves` included, is left to
/// ``LedgerJSON``. A status outside ``TaskStatus`` still fails the read.
public enum LedgerProgressJSON {
  public static func decode(_ data: Data) throws -> LedgerProgress {
    try JSONDecoder().decode(LedgerProgress.self, from: data)
  }
}

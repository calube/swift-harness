/// The long-lived task worktrees of one brownfield plan, and the branch each has checked out.
///
/// Xcode and SwiftPM build products name the absolute path of the tree they were built from, so
/// a new worktree at a new path builds every file cold. A slot keeps its path from task to task,
/// and with it its DerivedData and each package's `.build`: the next task in a slot rebuilds only
/// what differs from the last one.
public struct WorktreePoolState: Codable, Sendable, Equatable {
  public struct Slot: Codable, Sendable, Equatable {
    /// The worktree's absolute path, the same for every task the slot takes.
    public let path: String
    /// The task or fix branch checked out there; `nil` while the slot is free.
    public var branch: String?

    public init(path: String, branch: String?) {
      self.path = path
      self.branch = branch
    }
  }

  public private(set) var slots: [Slot]

  public init(slots: [Slot] = []) {
    self.slots = slots
  }

  /// The path of the slot `branch` is checked out in.
  public func path(holding branch: String) -> String? {
    slots.first { $0.branch == branch }?.path
  }

  /// The first free slot, in the order the slots were added.
  public var firstFree: Slot? {
    slots.first { $0.branch == nil }
  }

  /// Marks the slot at `path` as holding `branch`, adding the slot when it's new.
  public mutating func assign(_ branch: String, to path: String) {
    if let index = slots.firstIndex(where: { $0.path == path }) {
      slots[index].branch = branch
    } else {
      slots.append(Slot(path: path, branch: branch))
    }
  }

  /// Adds a free slot at `path`; a slot already there keeps what it holds.
  public mutating func add(free path: String) {
    guard !slots.contains(where: { $0.path == path }) else { return }
    slots.append(Slot(path: path, branch: nil))
  }

  /// Frees the slot holding `branch`.
  /// - Returns: its path, or `nil` when no slot holds `branch`.
  @discardableResult
  public mutating func free(_ branch: String) -> String? {
    guard let index = slots.firstIndex(where: { $0.branch == branch }) else { return nil }
    slots[index].branch = nil
    return slots[index].path
  }

  /// Forgets the slot at `path`, as when its worktree is removed.
  public mutating func drop(_ path: String) {
    slots.removeAll { $0.path == path }
  }
}

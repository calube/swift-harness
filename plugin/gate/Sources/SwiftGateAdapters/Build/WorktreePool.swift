import Foundation
import SwiftGateDomain

/// A brownfield plan's pool of long-lived task worktrees, recorded in
/// `<common>/swift-harness/worktree-pool/<plan>.json`.
///
/// `worktree create` and a fix cut check their branch out in a free slot, adding one when none is
/// free; `worktree remove` returns it. A slot keeps its path, its DerivedData under its git dir and
/// its ignored build directories, so each task after a slot's first builds warm
/// (``WorktreePoolState``). One branch at a time is checked out in a slot, so each slot still has
/// 1 committer.
public struct WorktreePool: Sendable {
  public static let directoryName = "worktree-pool"
  /// What returning a slot keeps of its state root: the DerivedData each area built in, and the
  /// scratch trees a gate still running there owns.
  public static let keptState: Set<String> = ["derived-data", "scratch"]

  /// What ``checkOut(branch:from:workspace:)`` did.
  public struct Checkout: Sendable, Equatable {
    public let path: String
    /// `true` when the slot existed, so an earlier task's build products are there.
    public let reused: Bool
  }

  /// What ``dispose(workspace:)`` removed, and the slots it couldn't.
  public struct Disposal: Sendable, Equatable {
    public var removed: [String] = []
    public var failures: [String] = []
  }

  public let commonDirectory: String
  public let plan: String

  public init(commonDirectory: String, plan: String) {
    self.commonDirectory = commonDirectory
    self.plan = plan
  }

  /// `<common>/swift-harness/worktree-pool/<plan>.json`.
  public var file: URL {
    URL(filePath: commonDirectory, directoryHint: .isDirectory)
      .appending(path: "\(RunLayout.gitDirDirectory)/\(Self.directoryName)/\(plan).json")
  }

  /// The recorded slots; empty when the pool has none yet.
  public func state() throws(GitWorkspaceError) -> WorktreePoolState {
    guard FileManager.default.fileExists(atPath: file.path) else { return WorktreePoolState() }
    do {
      return try JSONDecoder().decode(WorktreePoolState.self, from: Data(contentsOf: file))
    } catch {
      throw .pool(path: file.path, detail: "unreadable: \(error)")
    }
  }

  /// The slot `branch` is checked out in, if a slot holds it.
  public func path(holding branch: String) throws(GitWorkspaceError) -> String? {
    try state().path(holding: branch)
  }

  /// Checks `branch` out new from `base` in the first free slot, or in a new slot when none is
  /// free, and records it there. `builds` is `false` for a task that builds no area.
  public func checkOut(
    branch: String, from base: String, builds: Bool = true, workspace: any GitWorkspace
  ) async throws(GitWorkspaceError) -> Checkout {
    try await locked { () async throws(GitWorkspaceError) -> Checkout in
      var state = try state()
      if let held = state.path(holding: branch) {
        throw .pool(path: held, detail: "\(branch) is already checked out here")
      }
      while let free = state.firstFree {
        guard FileManager.default.fileExists(atPath: free.path) else {
          state.drop(free.path)
          continue
        }
        try await workspace.switchWorktree(at: free.path, toNewBranch: branch, from: base)
        state.assign(branch, to: free.path)
        try write(state)
        return Checkout(path: free.path, reused: true)
      }
      let path = try newSlotPath(state)
      try await workspace.addWorktree(at: path, branch: branch, from: base)
      state.assign(branch, to: path)
      try write(state)
      return Checkout(path: path, reused: false)
    }
  }

  /// Adds free slots, each checked out detached at `revision`, until the pool holds `count`, so
  /// the warm-up can build in them before the first task takes one.
  /// - Returns: the paths of the slots it added, in slot order.
  public func prepare(count: Int, revision: String, workspace: any GitWorkspace)
    async throws(GitWorkspaceError) -> [String]
  {
    try await locked { () async throws(GitWorkspaceError) -> [String] in
      var state = try state()
      for slot in state.slots where !FileManager.default.fileExists(atPath: slot.path) {
        state.drop(slot.path)
      }
      var added: [String] = []
      while state.slots.count < count {
        let path = try newSlotPath(state)
        try await workspace.addDetachedWorktree(at: path, revision: revision)
        state.add(free: path)
        added.append(path)
        try write(state)
      }
      return added
    }
  }

  /// The holder a scratch checkout records in its slot: `scratch:<pid>:<token>`. A `:` is never
  /// in a branch name, and the pid lets a later checkout free a slot whose process died.
  public static func scratchHolder(pid: Int32, token: String) -> String {
    "\(scratchPrefix)\(pid):\(token)"
  }

  static let scratchPrefix = "scratch:"

  /// Checks `revision` out detached for `holder` in a free slot, the first `prefer` picks when
  /// one does, else the first free one, else a new slot. A slot a dead scratch holder left is
  /// reset and freed first. ``release(branch:discard:workspace:)`` with `holder` returns it.
  public func checkOutDetached(
    revision: String, holder: String, prefer: @Sendable (String) -> Bool = { _ in false },
    isAlive: @Sendable (Int32) -> Bool, workspace: any GitWorkspace
  ) async throws(GitWorkspaceError) -> Checkout {
    try await locked { () async throws(GitWorkspaceError) -> Checkout in
      var state = try state()
      if let held = state.path(holding: holder) {
        throw .pool(path: held, detail: "\(holder) already holds this slot")
      }
      for slot in state.slots {
        guard let pid = slot.branch.flatMap(Self.scratchPID), !isAlive(pid) else { continue }
        if FileManager.default.fileExists(atPath: slot.path) {
          try await workspace.resetWorktree(at: slot.path)
          try emptyState(of: slot.path)
        }
        state.free(slot.branch ?? "")
      }
      for slot in state.slots
      where slot.branch == nil && !FileManager.default.fileExists(atPath: slot.path) {
        state.drop(slot.path)
      }
      let free = state.slots.filter { $0.branch == nil }.map(\.path)
      if let path = free.first(where: prefer) ?? free.first {
        try await workspace.detachWorktree(at: path, revision: revision)
        state.assign(holder, to: path)
        try write(state)
        return Checkout(path: path, reused: true)
      }
      let path = try newSlotPath(state)
      try await workspace.addDetachedWorktree(at: path, revision: revision)
      state.assign(holder, to: path)
      try write(state)
      return Checkout(path: path, reused: false)
    }
  }

  /// The process a scratch holder names, or `nil` for a branch.
  static func scratchPID(_ holder: String) -> Int32? {
    guard holder.hasPrefix(scratchPrefix) else { return nil }
    return holder.dropFirst(scratchPrefix.count).split(separator: ":").first.flatMap {
      Int32($0)
    }
  }

  /// The first `<repo>-<plan>.slot-<n>` neither the pool nor the disk has.
  private func newSlotPath(_ state: WorktreePoolState) throws(GitWorkspaceError) -> String {
    var number = 1
    while true {
      let path = try TaskWorktree.slotPath(
        commonDirectory: commonDirectory, plan: plan, number: number)
      if !state.slots.contains(where: { $0.path == path })
        && !FileManager.default.fileExists(atPath: path)
      {
        return path
      }
      number += 1
    }
  }

  /// Returns the slot `branch` is checked out in: refuses one with uncommitted work unless
  /// `discard`, then detaches it, resets it, deletes its untracked files and empties its state root
  /// but for ``keptState``. The branch stays; its commits are untouched.
  /// - Returns: the slot's path, or `nil` when no slot holds `branch`.
  public func release(branch: String, discard: Bool, workspace: any GitWorkspace)
    async throws(GitWorkspaceError) -> String?
  {
    // Read once unlocked, so a repository without a pool never makes its directory.
    guard try path(holding: branch) != nil else { return nil }
    return try await locked { () async throws(GitWorkspaceError) -> String? in
      var state = try state()
      guard let path = state.path(holding: branch) else { return nil }
      guard FileManager.default.fileExists(atPath: path) else {
        state.drop(path)
        try write(state)
        return path
      }
      if !discard {
        let dirty = try await workspace.uncommittedPaths(inWorktree: path)
        guard dirty.isEmpty else {
          throw .pool(
            path: path,
            detail: "uncommitted changes in \(dirty.joined(separator: ", ")); commit or "
              + "discard them first")
        }
      }
      try await workspace.resetWorktree(at: path)
      try emptyState(of: path)
      state.free(branch)
      try write(state)
      return path
    }
  }

  /// Removes every slot's worktree, its DerivedData with it, and the pool's record: the run is
  /// over. A slot with a branch checked out loses its uncommitted edits; its branch stays.
  public func dispose(workspace: any GitWorkspace) async -> Disposal {
    var disposal = Disposal()
    let state: WorktreePoolState
    do throws(GitWorkspaceError) {
      state = try self.state()
    } catch {
      disposal.failures.append("\(error)")
      return disposal
    }
    var left = state
    for slot in state.slots {
      guard FileManager.default.fileExists(atPath: slot.path) else {
        left.drop(slot.path)
        continue
      }
      do throws(GitWorkspaceError) {
        try await workspace.removeWorktree(at: slot.path, force: true)
        disposal.removed.append(slot.path)
        left.drop(slot.path)
      } catch {
        disposal.failures.append("\(slot.path): \(error)")
      }
    }
    do throws(GitWorkspaceError) {
      if left.slots.isEmpty {
        if FileManager.default.fileExists(atPath: file.path) {
          do {
            try FileManager.default.removeItem(at: file)
          } catch {
            throw .pool(path: file.path, detail: "removing: \(error)")
          }
        }
      } else {
        try write(left)
      }
    } catch {
      disposal.failures.append("\(error)")
    }
    return disposal
  }

  /// Takes `worktree` away: returns its slot when it is pooled, else removes it with
  /// `git worktree remove`, forced when `discard`.
  public static func retire(
    _ worktree: TaskWorktree, discard: Bool, workspace: any GitWorkspace
  ) async throws(GitWorkspaceError) {
    let pool = WorktreePool(commonDirectory: worktree.commonDirectory, plan: worktree.plan)
    if try await pool.release(branch: worktree.branch, discard: discard, workspace: workspace)
      == nil
    {
      try await workspace.removeWorktree(at: worktree.path, force: discard)
    }
  }

  private func write(_ state: WorktreePoolState) throws(GitWorkspaceError) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    do {
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try encoder.encode(state).write(to: file, options: .atomic)
    } catch {
      throw .pool(path: file.path, detail: "writing: \(error)")
    }
  }

  /// Deletes what the slot's last task left in its state root, keeping ``keptState``.
  private func emptyState(of path: String) throws(GitWorkspaceError) {
    let root = StateRootResolver.resolve(worktree: URL(filePath: path, directoryHint: .isDirectory))
      .directory
    let files = FileManager.default
    guard let entries = try? files.contentsOfDirectory(atPath: root.path) else { return }
    for entry in entries where !Self.keptState.contains(entry) {
      do {
        try files.removeItem(at: root.appending(path: entry))
      } catch {
        throw .pool(path: path, detail: "emptying \(root.path): \(error)")
      }
    }
  }

  /// Runs `body` holding the pool's lock, so 2 commands never take the same free slot.
  private func locked<T: Sendable>(_ body: () async throws(GitWorkspaceError) -> T)
    async throws(GitWorkspaceError) -> T
  {
    let lock = FileCountingLock(
      directory: file.deletingLastPathComponent(), name: "\(plan).lock", capacity: 1,
      pollInterval: .milliseconds(5))
    let lease: LockLease
    do {
      lease = try await lock.acquire(timeout: .seconds(60))
    } catch {
      throw .pool(path: file.path, detail: "locking: \(error)")
    }
    defer { lease.release() }
    return try await body()
  }
}

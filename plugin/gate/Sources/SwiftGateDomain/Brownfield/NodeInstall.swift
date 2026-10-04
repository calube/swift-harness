import Foundation

/// A node package manager, as the lockfile beside a package names it.
public enum NodePackageManager: String, Sendable, Codable, CaseIterable {
  case npm, pnpm, yarn, bun

  /// Each lockfile and the manager that writes it, in the order a directory holding several is
  /// read.
  public static let lockfiles: [(file: String, manager: NodePackageManager)] = [
    ("pnpm-lock.yaml", .pnpm), ("yarn.lock", .yarn), ("bun.lock", .bun), ("bun.lockb", .bun),
    ("package-lock.json", .npm), ("npm-shrinkwrap.json", .npm),
  ]
}

/// 1 install of a node package's dependencies, frozen to its lockfile.
public struct NodeInstall: Sendable, Equatable {
  /// Repository-relative directory holding the lockfile, where the install runs; `.` is the root.
  public let directory: String
  public let manager: NodePackageManager
  /// Repository-relative.
  public let lockfile: String
  /// The arguments after the manager's name.
  public let arguments: [String]
  /// The configured areas this install serves, in config order; never empty.
  public let areas: [String]
  /// The arguments that print where the manager keeps its package cache or store.
  public let cachePathArguments: [String]

  public init(
    directory: String, manager: NodePackageManager, lockfile: String, arguments: [String],
    areas: [String], cachePathArguments: [String]
  ) {
    self.directory = directory
    self.manager = manager
    self.lockfile = lockfile
    self.arguments = arguments
    self.areas = areas
    self.cachePathArguments = cachePathArguments
  }

  /// The install as a person would type it.
  public var command: String {
    ([manager.rawValue] + arguments).joined(separator: " ")
  }
}

/// The node installs a worktree needs before any area command runs in it.
public struct NodeInstallPlan: Sendable, Equatable {
  public let installs: [NodeInstall]
  /// Node areas left without an install, and why.
  public let notes: [String]

  public init(installs: [NodeInstall], notes: [String]) {
    self.installs = installs
    self.notes = notes
  }

  /// 1 install per lockfile that a `node` area of `areas` sits at or under.
  public static func plan(areas: [BrownfieldArea], tree: TrackedTreeSnapshot) -> NodeInstallPlan {
    NodeInstallPlan(installs: [], notes: [])
  }
}

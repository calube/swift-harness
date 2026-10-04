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

  /// 1 install per lockfile that a `node` area of `areas` sits at or under: the nearest one at
  /// or above the area's root, so a workspace's packages share their root's install. A node area
  /// with no lockfile gets a note instead, since a frozen install needs one.
  public static func plan(areas: [BrownfieldArea], tree: TrackedTreeSnapshot) -> NodeInstallPlan {
    let listed = Set(tree.paths)
    var order: [String] = []
    var found: [String: (manager: NodePackageManager, lockfile: String, areas: [String])] = [:]
    var notes: [String] = []
    for area in areas where area.kind == .node {
      let root = normalized(area.root)
      guard let (directory, manager, lockfile) = nearestLockfile(from: root, listed: listed)
      else {
        notes.append(
          "\(area.name): no lockfile at or above \(root), so nothing was installed; its "
            + "commands run without node_modules")
        continue
      }
      if found[directory] == nil {
        order.append(directory)
        found[directory] = (manager, lockfile, [])
      }
      found[directory]?.areas.append(area.name)
    }
    let installs = order.compactMap { directory -> NodeInstall? in
      guard let entry = found[directory] else { return nil }
      let berry =
        entry.manager == .yarn
        && (tree.read(entry.lockfile).map { String(decoding: $0, as: UTF8.self) }?
          .contains("\n__metadata:") ?? false)
      return NodeInstall(
        directory: directory, manager: entry.manager, lockfile: entry.lockfile,
        arguments: arguments(entry.manager, berry: berry), areas: entry.areas,
        cachePathArguments: cachePathArguments(entry.manager, berry: berry))
    }
    return NodeInstallPlan(installs: installs, notes: notes)
  }

  /// `web`, `./web` and `web/` all name `web`; the root is `.`.
  static func normalized(_ root: String) -> String {
    let segments = root.split(separator: "/").filter { $0 != "." }
    return segments.isEmpty ? "." : segments.joined(separator: "/")
  }

  private static func nearestLockfile(from root: String, listed: Set<String>)
    -> (String, NodePackageManager, String)?
  {
    for directory in ManifestPaths.ancestors(root) {
      for (file, manager) in NodePackageManager.lockfiles {
        let path = ManifestPaths.join(directory, file)
        if listed.contains(path) { return (directory, manager, path) }
      }
    }
    return nil
  }

  /// Each manager's install that fails rather than rewrite the lockfile, reading the shared
  /// cache before the network. yarn 2 and later spell it `--immutable` and have no offline flag.
  private static func arguments(_ manager: NodePackageManager, berry: Bool) -> [String] {
    switch manager {
    case .pnpm: ["install", "--frozen-lockfile", "--prefer-offline"]
    case .npm: ["ci", "--prefer-offline", "--no-audit", "--no-fund"]
    case .yarn:
      berry ? ["install", "--immutable"] : ["install", "--frozen-lockfile", "--prefer-offline"]
    case .bun: ["install", "--frozen-lockfile"]
    }
  }

  private static func cachePathArguments(_ manager: NodePackageManager, berry: Bool) -> [String] {
    switch manager {
    case .pnpm: ["store", "path"]
    case .npm: ["config", "get", "cache"]
    case .yarn: berry ? ["config", "get", "cacheFolder"] : ["cache", "dir"]
    case .bun: ["pm", "cache"]
    }
  }
}

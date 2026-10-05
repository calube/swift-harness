import Foundation

/// Which areas a change gates. A file belongs to the area whose root holds it, the deepest when
/// roots nest; an Xcode area is gated too by a change in a local package it builds.
public enum AreaGating {
  /// The area whose root holds `path`, the deepest when roots nest; `nil` for a path no area
  /// holds.
  public static func owner(of path: String, in areas: [BrownfieldArea]) -> BrownfieldArea? {
    areas.filter { holds($0.root, path) }.max { $0.root.count < $1.root.count }
  }

  /// The areas `changed` (repository-relative) gates, in `areas`' order: each changed file's
  /// owner, and each Xcode area building a package that holds 1.
  public static func touched(by changed: [String], in areas: [BrownfieldArea]) -> [BrownfieldArea] {
    let owners = Set(changed.compactMap { owner(of: $0, in: areas)?.name })
    return areas.filter { area in
      owners.contains(area.name)
        || (area.xcode?.packages ?? []).contains { package in
          changed.contains { holds(package, $0) }
        }
    }
  }

  private static func holds(_ directory: String, _ path: String) -> Bool {
    let root = directory.split(separator: "/").filter { $0 != "." }.joined(separator: "/")
    return root.isEmpty || path == root || path.hasPrefix(root + "/")
  }
}

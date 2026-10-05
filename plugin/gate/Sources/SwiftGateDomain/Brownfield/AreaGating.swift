import Foundation

/// Which areas a change gates. A file belongs to the area whose root holds it, the deepest when
/// roots nest; an Xcode area is gated too by a change in a local package it builds.
public enum AreaGating {
  /// The area whose root holds `path`, the deepest when roots nest; `nil` for a path no area
  /// holds.
  public static func owner(of path: String, in areas: [BrownfieldArea]) -> BrownfieldArea? {
    areas.filter { area in
      let root = area.root.split(separator: "/").filter { $0 != "." }.joined(separator: "/")
      return root.isEmpty || path == root || path.hasPrefix(root + "/")
    }.max { $0.root.count < $1.root.count }
  }

  /// The areas `changed` (repository-relative) gates, in `areas`' order.
  public static func touched(by changed: [String], in areas: [BrownfieldArea]) -> [BrownfieldArea] {
    let owners = Set(changed.compactMap { owner(of: $0, in: areas)?.name })
    return areas.filter { owners.contains($0.name) }
  }
}

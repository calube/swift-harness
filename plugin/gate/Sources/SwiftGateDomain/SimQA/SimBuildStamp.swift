import Foundation

/// What the last good `sim up` build in a worktree's DerivedData was built from: the commit, the
/// uncommitted changes, the scheme and the container. A later `sim up` whose stamp is equal
/// installs those products again instead of building.
///
/// Stored as `build-stamp.json` inside the DerivedData folder it describes, so removing that
/// folder removes the stamp with it.
public struct SimBuildStamp: Codable, Sendable, Equatable {
  public static let currentSchemaVersion = 1
  public static let fileName = "build-stamp.json"
  /// The hash recorded for an uncommitted change that deletes its path.
  public static let deleted = "deleted"

  public let schemaVersion: Int
  public let head: String
  public let scheme: String
  /// The `.xcodeproj`, `.xcworkspace` or package the scheme was built from.
  public let container: String
  /// Each uncommitted path that can change the build, to its working-tree blob hash, or
  /// ``deleted``.
  public let changes: [String: String]

  public init(head: String, scheme: String, container: String, changes: [String: String]) {
    self.schemaVersion = Self.currentSchemaVersion
    self.head = head
    self.scheme = scheme
    self.container = container
    self.changes = changes
  }

  /// The uncommitted paths among `paths` that can change the build: all but the harness's own
  /// `.harness/` state, such as the flow files a validation worker writes beside the app.
  public static func buildInputs(_ paths: [String]) -> [String] {
    paths.filter { path in
      !path.split(separator: "/").dropLast().contains(Substring(RunLayout.treeDirectory))
    }
  }

  /// `container` as the stamp records it.
  public static func containerKey(_ container: XcodebuildContainer) -> String {
    switch container {
    case .package(let directory): "package:\(directory)"
    case .project(let path): "project:\(path)"
    case .workspace(let path): "workspace:\(path)"
    }
  }

  public func encoded() -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    // Strings, an integer and a string map always encode.
    return (try? encoder.encode(self)) ?? Data()
  }

  /// `nil` for anything that isn't a stamp of the current schema.
  public static func decode(_ data: Data) -> SimBuildStamp? {
    guard let stamp = try? JSONDecoder().decode(SimBuildStamp.self, from: data),
      stamp.schemaVersion == currentSchemaVersion
    else { return nil }
    return stamp
  }
}

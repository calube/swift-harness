import Foundation

/// `~/.swift-harness/projects.json`: the bootstrapped repositories on this machine, as absolute
/// paths. Pointers only; each repository's `.harness/plans/index.json` stays canonical (spec §4.2).
public struct ProjectRegistry: Sendable, Equatable {
  public static let schema = 1
  /// Relative to the home directory.
  public static let path = ".swift-harness/projects.json"

  /// Sorted and unique.
  public let projects: [String]

  public init(projects: [String]) {
    self.projects = Array(Set(projects)).sorted()
  }

  public func adding(_ path: String) -> ProjectRegistry {
    ProjectRegistry(projects: projects + [path])
  }

  public static func decode(_ data: Data) throws -> ProjectRegistry {
    let wire = try JSONDecoder().decode(Wire.self, from: data)
    guard wire.schema == schema else {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: [], debugDescription: "schema \(wire.schema) is not \(schema)"))
    }
    return ProjectRegistry(projects: wire.projects)
  }

  public func encoded() -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    // Encoding two plain fields cannot fail.
    let data = (try? encoder.encode(Wire(schema: Self.schema, projects: projects))) ?? Data()
    return String(decoding: data, as: UTF8.self) + "\n"
  }

  private struct Wire: Codable {
    let schema: Int
    let projects: [String]
  }
}

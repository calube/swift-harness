import Foundation

/// `<common>/swift-harness/committed-config-set-aside.json`: `swiftgate run` found a committed
/// `.swiftgate.toml` and ran the clone on the brownfield profile anyway. Every worktree of the
/// clone then reads the common dir's `config.toml` and keeps its state under its git dir, while
/// the committed file stays in the tree as it was.
///
/// The run adopts no owned config: an owned profile's gates and standards judge code the run
/// didn't touch, and `run` plans, builds and reports through areas only discovery writes.
public struct CommittedConfigSetAside: Codable, Sendable, Equatable {
  public static let fileName = "committed-config-set-aside.json"

  /// The committed config's path from the worktree root.
  public let file: String
  /// `git hash-object` of the file when it was set aside; `nil` when git couldn't hash it.
  public let blob: String?
  public let setAsideAt: Date

  public init(file: String = Config.fileName, blob: String?, setAsideAt: Date) {
    self.file = file
    self.blob = blob
    self.setAsideAt = setAsideAt
  }

  /// Pretty, key-sorted JSON with an ISO 8601 time and a trailing newline.
  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(self) + Data("\n".utf8)
  }

  public static func decode(_ data: Data) throws -> CommittedConfigSetAside {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(Self.self, from: data)
  }

  /// The report's line for it.
  public var reportLine: String {
    "\(file)" + (blob.map { " (blob \($0))" } ?? "") + " set aside for this clone at "
      + setAsideAt.formatted(.iso8601) + ": every command ran the brownfield profile, and the "
      + "file is unchanged in the tree"
  }
}

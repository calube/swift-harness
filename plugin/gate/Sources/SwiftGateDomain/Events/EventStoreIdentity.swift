import Foundation

/// `.harness/events/store.json`: names 1 store, so a copy imported into another checkout keeps
/// its name, and holds the salt that hashes hook input.
public struct EventStoreIdentity: Sendable, Equatable, Codable {
  public static let schemaVersion = 1
  public static let saltBytes = 32

  public let schemaVersion: Int
  /// A lowercase UUID.
  public let storeID: String
  /// ``saltBytes`` random bytes as lowercase hex.
  public let salt: String

  /// `nil` unless `salt` is ``saltBytes`` long.
  public init?(storeID: UUID, salt: [UInt8]) {
    return nil
  }
}

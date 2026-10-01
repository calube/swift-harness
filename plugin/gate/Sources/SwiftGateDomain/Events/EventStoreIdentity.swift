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
    guard salt.count == Self.saltBytes else { return nil }
    self.schemaVersion = Self.schemaVersion
    self.storeID = storeID.uuidString.lowercased()
    self.salt = salt.map { String(format: "%02x", $0) }.joined()
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, storeID, salt
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
    guard schemaVersion == Self.schemaVersion else {
      throw DecodingError.dataCorruptedError(
        forKey: .schemaVersion, in: c,
        debugDescription: "unsupported schemaVersion \(schemaVersion)")
    }
    let id = try c.decode(String.self, forKey: .storeID)
    guard let parsed = UUID(uuidString: id), parsed.uuidString.lowercased() == id else {
      throw DecodingError.dataCorruptedError(
        forKey: .storeID, in: c, debugDescription: "`\(id)` isn't a lowercase UUID")
    }
    storeID = id
    salt = try c.decode(String.self, forKey: .salt)
    guard salt.utf8.count == Self.saltBytes * 2,
      salt.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) })
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .salt, in: c,
        debugDescription: "not \(Self.saltBytes) bytes of lowercase hex")
    }
  }
}

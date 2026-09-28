import Foundation
import Testing

@testable import SwiftGateDomain

@Suite("Session record")
struct SessionRecordTests {
  static let hash = String(repeating: "ab", count: 32)

  static func record(
    id: String = "8f2c1d7e-5b4a-4c1e-9d3f-2a6b7c8d9e0f", transcriptPath: String? = "/t/x.jsonl"
  ) throws -> SessionRecord {
    try SessionRecord(
      sessionId: id, recordedAt: Date(timeIntervalSince1970: 1_790_000_000.25),
      pluginRoot: "/plugins/swift-harness", pluginVersion: "0.1.0", treeHash: hash,
      transcriptPath: transcriptPath)
  }

  /// A valid record's JSON with `edit` applied to its object.
  static func json(_ edit: (inout [String: Any]) -> Void) throws -> Data {
    var object = try #require(
      try JSONSerialization.jsonObject(with: try record().encoded()) as? [String: Any])
    edit(&object)
    return try JSONSerialization.data(withJSONObject: object)
  }

  @Test(
    "a record survives an encode and decode unchanged, with and without a transcript path, under exactly the documented keys — catches a field lost or renamed on disk"
  )
  func roundTrip() throws {
    for record in [try Self.record(), try Self.record(transcriptPath: nil)] {
      let data = try record.encoded()
      #expect(try SessionRecord.decode(data) == record)
      let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
      var keys: Set<String> = [
        "schemaVersion", "sessionId", "recordedAt", "pluginRoot", "pluginVersion", "treeHash",
      ]
      if record.transcriptPath != nil { keys.insert("transcriptPath") }
      #expect(Set(object.keys) == keys)
      #expect(object["schemaVersion"] as? Int == 1)
      #expect(object["recordedAt"] as? String == "2026-09-21T14:13:20.250Z")
    }
  }

  @Test(
    "an unknown key fails decoding naming the key — catches a closed record silently accepting fields it doesn't understand"
  )
  func unknownKeyFails() throws {
    let data = try Self.json { $0["pluginHash"] = "x" }
    #expect(throws: SessionRecordError.unknownKey("pluginHash")) {
      try SessionRecord.decode(data)
    }
  }

  @Test(
    "an unknown schemaVersion fails decoding naming the version, even alongside keys it doesn't know — catches a future record read as this one"
  )
  func unknownVersionFails() throws {
    let data = try Self.json {
      $0["schemaVersion"] = 2
      $0["newField"] = true
    }
    #expect(throws: SessionRecordError.unsupportedSchemaVersion(2)) {
      try SessionRecord.decode(data)
    }
  }

  @Test(
    "a missing key, a malformed date or hash, or an unsafe session id fails decoding — catches a half-written or hostile record being trusted",
    arguments: ["missing treeHash", "bad date", "short hash", "unsafe id"])
  func malformedFails(problem: String) throws {
    let data = try Self.json { object in
      switch problem {
      case "missing treeHash": object["treeHash"] = nil
      case "bad date": object["recordedAt"] = "yesterday"
      case "short hash": object["treeHash"] = "abc"
      default: object["sessionId"] = "../x"
      }
    }
    #expect(throws: SessionRecordError.self) { try SessionRecord.decode(data) }
    #expect((try? SessionRecord.decode(data)) == nil)
  }

  @Test(
    "only one safe path component is a session id: '/', '..', empty, a leading dot and over-long ids are refused — catches a session id naming a file outside the records directory",
    arguments: [
      ("", false), ("/", false), ("..", false), (".", false), ("../x", false), ("a/b", false),
      (".hidden", false), ("a b", false), ("ü", false), (String(repeating: "a", count: 129), false),
      (String(repeating: "a", count: 128), true), ("8f2c1d7e-5b4a-4c1e-9d3f-2a6b7c8d9e0f", true),
      ("session_1.2", true),
    ])
  func safeSessionIDs(id: String, safe: Bool) {
    #expect(SessionRecord.isSafeSessionID(id) == safe, "\(id)")
  }

  @Test(
    "a record can't be built for an unsafe session id — catches an unsafe id reaching the store"
  )
  func unsafeIdRefused() {
    for id in ["", "/", "..", "../x"] {
      #expect(throws: SessionRecordError.unsafeSessionID(id)) { try Self.record(id: id) }
    }
  }
}

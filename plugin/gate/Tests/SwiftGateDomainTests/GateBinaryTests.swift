import Foundation
import SwiftGateDomain
import Testing

@Suite("the gate binary an event names")
struct GateBinaryTests {
  static let hash = "b49790db12112294"

  static func event(binary: GateBinary?) -> HarnessEvent {
    HarnessEvent(
      eventID: "e-1", time: Date(timeIntervalSince1970: 1_790_000_000),
      source: HarnessEventSource(route: .hook, hook: .preToolUse, binary: binary),
      payload: .buildHalt(
        BuildHaltEvent(buildRun: "20261004T120000Z-0000002b", task: nil, reason: .question)))
  }

  @Test(
    "a source hash that is a path, too short, or upper case is refused, and a version holding a slash is — catches an absolute path written into every event",
    arguments: [
      "/Users/someone/.cache/swift-harness/bin/b49790db12112294/swiftgate", "b49790db",
      "B49790DB12112294", "~/b49790db1211229",
    ]
  )
  func refusesNonHashes(_ value: String) throws {
    #expect(throws: GateBinary.Invalid.sourceHash) {
      try GateBinary(sourceHash: value, pluginVersion: nil)
    }
    #expect(throws: GateBinary.Invalid.pluginVersion) {
      try GateBinary(sourceHash: Self.hash, pluginVersion: "/opt/plugins/1.0")
    }
    #expect(
      try GateBinary(sourceHash: Self.hash, pluginVersion: "1.2.0-beta+3").sourceHash == Self.hash)
  }

  @Test(
    "an event line whose binary is an absolute path fails to decode — catches a hand-written or older line smuggling a path past the type"
  )
  func decodingRefusesAPath() throws {
    let line = try HarnessEventJSON.encodeLine(
      Self.event(binary: try GateBinary(sourceHash: Self.hash, pluginVersion: nil)))
    let text = String(decoding: line, as: UTF8.self)
    #expect(text.contains("\"binary\":{\"sourceHash\":\"\(Self.hash)\"}"), "\(text)")
    let tampered = text.replacingOccurrences(of: Self.hash, with: "/Users/someone/bin/swiftgate")
    #expect(throws: HarnessEventDecodeError.self) {
      try HarnessEventJSON.decode(Data(tampered.utf8))
    }
    #expect(try HarnessEventJSON.decode(line).events.first?.source.binary?.sourceHash == Self.hash)
  }

  @Test(
    "the shim's hash and the manifest's version make the binary; no manifest or no version leaves the version out — catches the shim's hash dropped on the way in"
  )
  func readsTheShim() throws {
    let manifest = Data(#"{"name":"swift-harness","version":"0.4.1"}"#.utf8)
    let both = GateBinary.read(sourceHash: Self.hash, pluginManifest: manifest)
    #expect(both.binary == (try GateBinary(sourceHash: Self.hash, pluginVersion: "0.4.1")))
    #expect(both.problems.isEmpty)

    let unversioned = GateBinary.read(
      sourceHash: Self.hash, pluginManifest: Data(#"{"name":"swift-harness"}"#.utf8))
    #expect(unversioned.binary == (try GateBinary(sourceHash: Self.hash, pluginVersion: nil)))
    #expect(unversioned.problems.isEmpty)
    #expect(
      GateBinary.read(sourceHash: Self.hash, pluginManifest: nil).binary?.sourceHash == Self.hash)
  }

  @Test(
    "an unset hash names no binary and says nothing, while a path-valued one names none and says so without echoing it — catches a silent or path-leaking fallback"
  )
  func noShimOrABadValue() {
    let none = GateBinary.read(sourceHash: nil, pluginManifest: nil)
    #expect(none == GateBinary.Reading(binary: nil, problems: []))

    let path = "/Users/someone/.cache/swift-harness/bin/b49790db12112294/swiftgate"
    let bad = GateBinary.read(sourceHash: path, pluginManifest: nil)
    #expect(bad.binary == nil)
    #expect(bad.problems.count == 1)
    #expect(
      bad.problems.allSatisfy { !$0.contains(path) && $0.contains(GateBinary.sourceHashVariable) })

    let badVersion = GateBinary.read(
      sourceHash: Self.hash, pluginManifest: Data(#"{"version":"/opt/x"}"#.utf8))
    #expect(badVersion.binary == (try? GateBinary(sourceHash: Self.hash, pluginVersion: nil)))
    #expect(badVersion.problems.count == 1)
    #expect(badVersion.problems.allSatisfy { !$0.contains("/opt/x") })
  }

  @Test(
    "stamping fills an event's missing binary and keeps one it already names — catches an event left without the hash, or another binary's hash overwritten"
  )
  func stamping() throws {
    let mine = try GateBinary(sourceHash: Self.hash, pluginVersion: nil)
    let other = try GateBinary(sourceHash: "0000000000000000", pluginVersion: "1.0")
    #expect(Self.event(binary: nil).stamped(mine).source.binary == mine)
    #expect(Self.event(binary: other).stamped(mine).source.binary == other)
    #expect(Self.event(binary: nil).stamped(nil).source.binary == nil)
    let stamped = Self.event(binary: nil).stamped(mine)
    #expect(stamped.source.route == .hook)
    #expect(stamped.source.hook == .preToolUse)
    #expect(stamped.eventID == "e-1")
  }
}

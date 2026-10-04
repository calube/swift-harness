import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("events name the gate binary that wrote them")
struct GateBinaryWritingTests {
  static let hash = "b49790db12112294"

  static func temporaryRoot() -> URL {
    TestTemporaryDirectory.root.appending(
      path: "swiftgate-binary-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  static func halt(_ id: String) -> HarnessEvent {
    HarnessEvent(
      eventID: id, time: Date(timeIntervalSince1970: 1_790_000_000),
      source: HarnessEventSource(route: nil),
      payload: .buildHalt(
        BuildHaltEvent(buildRun: "20261004T120000Z-0000002b", task: nil, reason: .question)))
  }

  static func written(_ root: URL) throws -> [HarnessEvent] {
    let data = try #require(try HarnessEventFiles(root: root).read(.build, runID: nil))
    return try HarnessEventJSON.decode(data).events
  }

  @Test(
    "a writer built while the binary is bound writes its hash into every event, a batch included — catches an event written without the binary hash when the shim set it"
  )
  func boundWriterStamps() throws {
    let root = Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try GateBinary(sourceHash: Self.hash, pluginVersion: "0.4.1")

    try GateBinaryScope.$current.withValue(binary) {
      try EventWriterFactory.make(root: root, enabled: true).append(Self.halt("one"))
      try HarnessEventFiles(root: root).append(contentsOf: [Self.halt("two"), Self.halt("three")])
    }
    try HarnessEventFiles(root: root).append(Self.halt("unbound"))

    let events = try Self.written(root)
    #expect(events.map(\.eventID) == ["one", "two", "three", "unbound"])
    #expect(events.prefix(3).allSatisfy { $0.source.binary == binary })
    #expect(events.last?.source.binary == nil)
  }

  @Test(
    "the reader takes the shim's hash and the version in the plugin root's manifest — catches the shim's variables never reaching the binary"
  )
  func readerReadsTheShim() throws {
    let root = Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = root.appending(path: GateBinaryReader.manifestPath)
    try FileManager.default.createDirectory(
      at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"name":"swift-harness","version":"0.4.1"}"#.utf8).write(to: manifest)

    let reading = GateBinaryReader.read(environment: [
      GateBinary.sourceHashVariable: Self.hash, GateBinaryReader.harnessRootVariable: root.path,
    ])
    #expect(reading.binary == (try GateBinary(sourceHash: Self.hash, pluginVersion: "0.4.1")))
    #expect(reading.problems.isEmpty)

    let noRoot = GateBinaryReader.read(environment: [GateBinary.sourceHashVariable: Self.hash])
    #expect(noRoot.binary == (try GateBinary(sourceHash: Self.hash, pluginVersion: nil)))
    #expect(GateBinaryReader.read(environment: [:]).binary == nil)
  }
}

import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// Loading the pinned tool's step schemas from the plugin.
@Suite("tool schema store")
struct ToolSchemaStoreTests {
  static let pluginRoot = Fixture.checkoutRoot

  @Test(
    "the plugin's captured schemas load at the pin with every command a batch step may name — catches a store that loads nothing"
  )
  func loadsThePin() throws {
    let schemas = try ToolSchemaStore.load(pluginRoot: Self.pluginRoot)

    #expect(schemas.version == AgentDevicePin.version)
    #expect(
      ["wait", "is", "press", "get", "snapshot", "screenshot"].allSatisfy {
        schemas.commands[$0] != nil
      })
    #expect(schemas.commands["batch"] != nil)
  }

  @Test(
    "a schema file whose version differs from the pin fails loading naming both versions — catches steps checked against another release's schemas"
  )
  func versionMismatch() throws {
    let root = try TestTemporaryDirectory.make("tool-schemas")
    defer { TestTemporaryDirectory.remove(root) }
    let pinned = try String(
      contentsOf: Self.pluginRoot.appending(path: AgentDevicePin.schemasPath), encoding: .utf8)
    let pinLine = "\"version\": \"\(AgentDevicePin.version)\""
    try #require(pinned.contains(pinLine))
    let other = pinned.replacingOccurrences(of: pinLine, with: "\"version\": \"0.21.20\"")
    let file = root.appending(path: AgentDevicePin.schemasPath)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(other.utf8).write(to: file)

    let error = #expect(throws: ToolSchemaStoreError.self) {
      _ = try ToolSchemaStore.load(pluginRoot: root)
    }

    #expect(
      error == .versionMismatch(path: file.path, found: "0.21.20", pin: AgentDevicePin.version))
    let message = error.map(String.init(describing:)) ?? ""
    #expect(message.contains("0.21.20") && message.contains(AgentDevicePin.version))
  }

  @Test(
    "a plugin root with no schema file fails loading naming the path — catches a missing file read as no schemas"
  )
  func missingFile() throws {
    let root = try TestTemporaryDirectory.make("tool-schemas-missing")
    defer { TestTemporaryDirectory.remove(root) }

    let error = #expect(throws: ToolSchemaStoreError.self) {
      _ = try ToolSchemaStore.load(pluginRoot: root)
    }

    guard case .unreadable(let path, _) = error else {
      Issue.record("expected unreadable, got \(String(describing: error))")
      return
    }
    #expect(path == root.appending(path: AgentDevicePin.schemasPath).path)
  }
}

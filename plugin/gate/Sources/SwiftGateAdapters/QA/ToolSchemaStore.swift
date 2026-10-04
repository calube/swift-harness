import Foundation
import SwiftGateDomain

/// Loads the pinned tool's step schemas from the plugin, where the capture wrote them.
public enum ToolSchemaStore {
  /// - Throws: when the file is missing or doesn't read, or records another version than `pin`.
  public static func load(pluginRoot: URL, pin: String = AgentDevicePin.version)
    throws(ToolSchemaStoreError) -> ToolSchemas
  {
    throw .unreadable(path: "", reason: "")
  }
}

public enum ToolSchemaStoreError: Error, Sendable, Equatable, CustomStringConvertible {
  case unreadable(path: String, reason: String)
  case invalid(path: String, FlowSchemaError)
  /// The file holds schemas for `found`, and the adapter is pinned to `pin`.
  case versionMismatch(path: String, found: String, pin: String)

  public var description: String {
    ""
  }
}

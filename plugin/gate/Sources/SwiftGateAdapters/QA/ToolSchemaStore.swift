import Foundation
import SwiftGateDomain

/// Loads the pinned tool's step schemas from the plugin, where the capture wrote them.
public enum ToolSchemaStore {
  /// - Throws: when the file is missing or doesn't read, or records another version than `pin`.
  public static func load(pluginRoot: URL, pin: String = AgentDevicePin.version)
    throws(ToolSchemaStoreError) -> ToolSchemas
  {
    let file = pluginRoot.appending(path: "qa/agent-device-schemas-\(pin).json")
    let data: Data
    do {
      data = try Data(contentsOf: file)
    } catch {
      throw .unreadable(path: file.path, reason: error.localizedDescription)
    }
    let schemas: ToolSchemas
    do {
      schemas = try ToolSchemas.parse(data)
    } catch {
      throw .invalid(path: file.path, error)
    }
    guard schemas.version == pin else {
      throw .versionMismatch(path: file.path, found: schemas.version, pin: pin)
    }
    return schemas
  }
}

public enum ToolSchemaStoreError: Error, Sendable, Equatable, CustomStringConvertible {
  case unreadable(path: String, reason: String)
  case invalid(path: String, FlowSchemaError)
  /// The file holds schemas for `found`, and the adapter is pinned to `pin`.
  case versionMismatch(path: String, found: String, pin: String)

  public var description: String {
    switch self {
    case .unreadable(let path, let reason): "\(path): \(reason)"
    case .invalid(let path, let error): "\(path): \(error)"
    case .versionMismatch(let path, let found, let pin):
      "\(path) holds schemas for agent-device \(found), but the adapter is pinned to \(pin)"
    }
  }
}

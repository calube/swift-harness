import Foundation

/// 1 JSON Schema from the pinned tool's MCP `tools/list`, read with the closed set of keywords
/// those schemas use. A keyword outside it fails reading, naming itself, so a schema this type
/// would half-check never loads.
public final class FlowSchema: Sendable {
  public init(json: FlowJSON, at path: String) throws(FlowSchemaError) {}

  /// Every way `value` breaks this schema, each naming its place under `path`; empty when it
  /// conforms.
  public func violations(of value: FlowJSON, at path: String) -> [String] {
    []
  }
}

/// Why a schema file or 1 of its schemas can't be read, naming where.
public struct FlowSchemaError: Error, Sendable, Equatable, CustomStringConvertible {
  public let path: String
  public let reason: String

  public init(path: String, reason: String) {
    self.path = path
    self.reason = reason
  }

  public var description: String { "" }
}

/// The pinned tool's step schemas: the shape of 1 batch step, and each command's input.
public struct ToolSchemas: Sendable {
  /// The `serverInfo.version` the schemas were captured from.
  public let version: String
  /// `batch`'s `steps.items`: which commands a step may name and which keys a step holds.
  public let step: FlowSchema
  /// Each tool's `inputSchema`, by tool name.
  public let commands: [String: FlowSchema]

  public init(version: String, step: FlowSchema, commands: [String: FlowSchema]) {
    self.version = version
    self.step = step
    self.commands = commands
  }

  /// Reads `{"serverInfo": {"version"}, "tools": [{"name", "inputSchema"}]}`, as the capture
  /// writes it.
  public static func parse(_ data: Data) throws(FlowSchemaError) -> ToolSchemas {
    throw FlowSchemaError(path: "", reason: "")
  }
}

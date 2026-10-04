/// The one `agent-device` version the adapter parses. The fixtures under
/// `Tests/Fixtures/AgentDevice/` and the step schemas under the plugin's `qa/` folder are captured
/// at this version, so a bump recaptures both.
public enum AgentDevicePin {
  public static let version = "0.0.0"

  public static var installCommand: String { "npm i -g agent-device@\(version)" }

  /// The captured MCP `tools/list` schemas, relative to the plugin root.
  public static var schemasPath: String { "qa/agent-device-schemas-\(version).json" }
}

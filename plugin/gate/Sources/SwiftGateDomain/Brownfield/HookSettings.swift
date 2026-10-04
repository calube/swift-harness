import Foundation

/// Turns the plugin's `hooks/hooks.json` into the settings file `swiftgate claude` passes to
/// `claude --settings`, so a brownfield clone gets the hooks without a file in its tree.
public enum HookSettings {
  /// Claude Code sets this only for a plugin's own hooks; a settings file's hooks run without it.
  public static let pluginRootVariable = "${CLAUDE_PLUGIN_ROOT}"

  /// The `hooks` table of `hooksJSON` with every `${CLAUDE_PLUGIN_ROOT}` replaced by
  /// `pluginRoot`, as a settings file. `nil` when `hooksJSON` holds no hook table, or
  /// `pluginRoot` isn't absolute, since a relative command would resolve against whatever
  /// directory the session runs in.
  public static func render(hooksJSON: Data, pluginRoot: String) -> Data? {
    guard pluginRoot.hasPrefix("/"),
      let object = try? JSONSerialization.jsonObject(with: hooksJSON) as? [String: Any],
      let hooks = object["hooks"] as? [String: Any], !hooks.isEmpty
    else { return nil }
    let root = pluginRoot.count > 1 && pluginRoot.hasSuffix("/") ? String(pluginRoot.dropLast()) : pluginRoot
    let settings: [String: Any] = ["hooks": substitute(hooks, root: root)]
    return try? JSONSerialization.data(
      withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
  }

  private static func substitute(_ value: Any, root: String) -> Any {
    switch value {
    case let text as String:
      return text.replacingOccurrences(of: pluginRootVariable, with: root)
    case let array as [Any]:
      return array.map { substitute($0, root: root) }
    case let table as [String: Any]:
      return table.mapValues { substitute($0, root: root) }
    default:
      return value
    }
  }
}

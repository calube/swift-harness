import Foundation

/// Which registration started a `swiftgate hook` process: the plugin's own `hooks/hooks.json`, or
/// the settings file ``HookSettings`` renders for a brownfield clone. A session that loads the
/// plugin and that settings file registers every event twice, so the hook needs to know which
/// one it is to let exactly one of them act.
public enum HookSource: String, Sendable, CaseIterable {
  case plugin
  case settings
}

/// Turns the plugin's `hooks/hooks.json` into the settings file `swiftgate claude` passes to
/// `claude --settings`, so a brownfield clone gets the hooks without a file in its tree.
public enum HookSettings {
  /// Claude Code sets this only for a plugin's own hooks; a settings file's hooks run without it.
  public static let pluginRootVariable = "${CLAUDE_PLUGIN_ROOT}"

  /// Sets the plugin root in each hook's environment without a shell, so a root with spaces or
  /// quotes needs no escaping.
  public static let environmentCommand = "/usr/bin/env"
  /// A brownfield clone's Stop hook gates at `slice`, whatever the plugin's own Stop says.
  public static let stopStatusMessage = "swiftgate check --tier slice"

  /// The `hooks` table of `hooksJSON` as a settings file. Each hook runs through
  /// ``environmentCommand``, which sets `CLAUDE_PLUGIN_ROOT` to `pluginRoot` and runs the hook's
  /// command with `${CLAUDE_PLUGIN_ROOT}` replaced and `--source settings` appended. `nil` when
  /// `hooksJSON` holds no hook table or a hook with no command, or `pluginRoot` isn't absolute, since a relative command
  /// would resolve against whatever directory the session runs in.
  public static func render(hooksJSON: Data, pluginRoot: String) -> Data? {
    guard pluginRoot.hasPrefix("/"),
      let object = try? JSONSerialization.jsonObject(with: hooksJSON) as? [String: Any],
      let hooks = object["hooks"] as? [String: Any], !hooks.isEmpty
    else { return nil }
    let root =
      pluginRoot.count > 1 && pluginRoot.hasSuffix("/")
      ? String(pluginRoot.dropLast()) : pluginRoot
    var table: [String: Any] = [:]
    for (event, groups) in hooks {
      guard let groups = groups as? [[String: Any]] else { return nil }
      table[event] = try? groups.map { group in
        var group = group
        guard let commands = group["hooks"] as? [[String: Any]] else { throw Unrenderable() }
        group["hooks"] = try commands.map { try settingsHook($0, event: event, root: root) }
        return group
      }
      if table[event] == nil { return nil }
    }
    let settings: [String: Any] = ["hooks": table]
    return try? JSONSerialization.data(
      withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
  }

  private struct Unrenderable: Error {}

  private static func settingsHook(_ hook: [String: Any], event: String, root: String) throws
    -> [String: Any]
  {
    guard let command = hook["command"] as? String else { throw Unrenderable() }
    let arguments = (hook["args"] as? [String]) ?? []
    var rendered = hook
    rendered["command"] = environmentCommand
    rendered["args"] =
      ["CLAUDE_PLUGIN_ROOT=\(root)", substitute(command, root: root)]
      + arguments.map { substitute($0, root: root) }
      + ["--source", HookSource.settings.rawValue]
    if event == "Stop", rendered["statusMessage"] != nil {
      rendered["statusMessage"] = stopStatusMessage
    }
    return rendered
  }

  private static func substitute(_ text: String, root: String) -> String {
    text.replacingOccurrences(of: pluginRootVariable, with: root)
  }
}

import Foundation

/// Turns the plugin's `hooks/hooks.json` into the settings file `swiftgate claude` passes to
/// `claude --settings`, so a brownfield clone gets the hooks without a file in its tree.
public enum HookSettings {
  /// `nil` when `hooksJSON` can't be turned into settings.
  public static func render(hooksJSON: Data, pluginRoot: String) -> Data? { nil }
}
